package mobile

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	poiIndexFilename = ".poi-v1.idx"
	poiIndexMagic    = "OSMPOI01"
	poiFooterBytes   = 8 + 2*sha256.Size
	poiIndexZoom     = 14
	maxTilePOIs      = 512
)

// Spatial postings reuse the bounded external sorter and compressed index.
// They address the original search records, so neither names nor detail text
// are duplicated in a regional in-memory catalog or in another data file.
type poiIndex struct {
	search          *searchReader
	removePath      string
	removeDirectory string
}

func (p *poiIndex) close() {
	if p == nil {
		return
	}
	_ = p.search.index.Close()
	if p.removePath != "" {
		_ = os.Remove(p.removePath)
	}
	if p.removeDirectory != "" {
		_ = os.RemoveAll(p.removeDirectory)
	}
}

func openPOIIndex(ctx context.Context, directory string, source *searchReader, sourceHash string) (*poiIndex, error) {
	path := filepath.Join(directory, poiIndexFilename)
	workspace := filepath.Join(directory, poiWorkDirectory)
	release, err := acquirePOILock(ctx, directory)
	persistent := err == nil
	if release != nil {
		defer release()
		persistent = cleanPOIWorkspace(workspace) == nil
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if cached, err := readPOIIndex(ctx, path, source, sourceHash); err == nil {
		return cached, nil
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if persistent {
		persistent = os.Mkdir(workspace, 0o700) == nil
	}
	if !persistent {
		// Read-only regions and platforms without file locks keep every sort
		// run in private OS temporary storage, never in the portable region.
		workspace, err = os.MkdirTemp("", "osmmini-poi-*")
		if err != nil {
			return nil, err
		}
	}
	defer os.RemoveAll(workspace)
	staged := filepath.Join(workspace, "index")
	if err := buildPOIIndex(ctx, staged, source, sourceHash); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if persistent && os.Rename(staged, path) == nil {
		return readPOIIndex(ctx, path, source, sourceHash)
	}
	index, err := readPOIIndex(ctx, staged, source, sourceHash)
	if err != nil {
		return nil, err
	}
	// Unlink immediately where supported, so a killed app leaves no large
	// temporary index behind. The open descriptor remains valid on Apple OSes.
	if err := os.Remove(staged); err != nil {
		index.removePath = staged
		index.removeDirectory = workspace
	}
	return index, nil
}

func indexDigest(ctx context.Context, file *os.File, size int64) ([]byte, error) {
	hash := sha256.New()
	reader := io.NewSectionReader(file, 0, size)
	var buffer [32 << 10]byte
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		n, err := reader.Read(buffer[:])
		if n > 0 {
			_, _ = hash.Write(buffer[:n])
		}
		if err == io.EOF {
			return hash.Sum(nil), nil
		}
		if err != nil {
			return nil, err
		}
	}
}

func readPOIIndex(ctx context.Context, path string, source *searchReader, sourceHash string) (_ *poiIndex, err error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = file.Close()
		}
	}()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() < searchCompactHeaderBytes+poiFooterBytes {
		return nil, errors.New("invalid POI index size")
	}
	length := info.Size() - poiFooterBytes
	var footer [poiFooterBytes]byte
	if _, err = file.ReadAt(footer[:], length); err != nil {
		return nil, err
	}
	sourceDigest, err := hex.DecodeString(sourceHash)
	if err != nil || len(sourceDigest) != sha256.Size || string(footer[:8]) != poiIndexMagic || !bytes.Equal(footer[8:8+sha256.Size], sourceDigest) {
		return nil, errors.New("POI index belongs to another search catalog")
	}
	digest, err := indexDigest(ctx, file, length)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(footer[8+sha256.Size:], digest) {
		return nil, errors.New("POI index checksum mismatch")
	}
	reader := &searchReader{
		data: source.data, index: file, dataBytes: source.dataBytes,
		compressedData: source.compressedData, dataBlocks: source.dataBlocks, dataDirectory: source.dataDirectory,
	}
	if err = reader.readIndexHeader(length); err != nil {
		return nil, err
	}
	if !reader.compact {
		return nil, errors.New("invalid POI index format")
	}
	return &poiIndex{search: reader}, nil
}

func buildPOIIndex(ctx context.Context, path string, source *searchReader, sourceHash string) error {
	sourceDigest, err := hex.DecodeString(sourceHash)
	if err != nil || len(sourceDigest) != sha256.Size {
		return errors.New("invalid search checksum")
	}
	builder := searchIndexBuilder{ctx: ctx, path: path}
	defer builder.close()
	err = scanPOIRecords(ctx, source, func(record SearchResult, offset uint64, length uint32) error {
		x, y := poiWorld(record)
		cell := poiCell(int(x*(1<<poiIndexZoom)), int(y*(1<<poiIndexZoom)), poiIndexZoom)
		return builder.add(searchPosting{term: poiKey(cell), offset: offset, length: length})
	})
	if err != nil {
		return err
	}
	if err = builder.finish(); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	length, err := file.Seek(0, io.SeekEnd)
	if err != nil {
		return err
	}
	digest, err := indexDigest(ctx, file, length)
	if err != nil {
		return err
	}
	var footer [poiFooterBytes]byte
	copy(footer[:8], poiIndexMagic)
	copy(footer[8:], sourceDigest)
	copy(footer[8+sha256.Size:], digest)
	if _, err = file.Write(footer[:]); err != nil {
		return err
	}
	return file.Sync()
}

func validPOI(record SearchResult) bool {
	lat, lon := record.Coordinate.Lat, record.Coordinate.Lon
	return (record.Kind == "node" || record.Kind == "way") && record.ID != 0 &&
		record.Place == "" && placeMinZoom(record.Category) < 0 &&
		boundedSourceText(record.Category, 256) != "" && boundedSourceText(record.Label, 2048) != "" &&
		!math.IsNaN(lat) && !math.IsNaN(lon) && math.Abs(lat) <= 90 && math.Abs(lon) <= 180
}

func scanPOIRecords(ctx context.Context, source *searchReader, visit func(SearchResult, uint64, uint32) error) error {
	var data io.Reader = io.NewSectionReader(source.data, 0, source.dataBytes)
	if source.compressedData {
		scratch := searchScratchPool.Get().(*searchScratch)
		defer searchScratchPool.Put(scratch)
		data = &searchDataStream{search: source, ctx: ctx, scratch: scratch}
	}
	reader := bufio.NewReaderSize(data, placeScanBufferBytes)
	var buffer []byte
	var offset uint64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, err := reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			buffer = append(buffer[:0], line...)
			for errors.Is(err, bufio.ErrBufferFull) {
				if err := ctx.Err(); err != nil {
					return err
				}
				line, err = reader.ReadSlice('\n')
				if len(buffer)+len(line) > maxSearchRecordBytes {
					return errors.New("POI search record exceeds size limit")
				}
				buffer = append(buffer, line...)
			}
			line = buffer
		}
		if err != nil && err != io.EOF {
			return err
		}
		if len(line) > 0 && bytes.Contains(line, []byte(`"category"`)) {
			var record SearchResult
			if err := json.Unmarshal(line, &record); err != nil {
				return err
			}
			if validPOI(record) {
				if err := visit(record, offset, uint32(len(line))); err != nil {
					return err
				}
			}
		}
		offset += uint64(len(line))
		if err == io.EOF {
			return nil
		}
	}
}

func poiWorld(record SearchResult) (float64, float64) {
	lat := max(-85.05112878, min(85.05112878, record.Coordinate.Lat)) * math.Pi / 180
	x := math.Mod((record.Coordinate.Lon+180)/360, 1)
	y := max(0, min(math.Nextafter(1, 0), (1-math.Asinh(math.Tan(lat))/math.Pi)/2))
	return x, y
}

// Interleaved x/y bits make each parent tile a contiguous posting range.
// Even a region imported with a lower maximum zoom needs only one lookup.
func poiCell(x, y, z int) uint32 {
	var cell uint32
	for bit := z - 1; bit >= 0; bit-- {
		cell = cell<<2 | uint32((y>>bit&1)<<1|(x>>bit&1))
	}
	return cell
}

func poiKey(cell uint32) string {
	key := strconv.FormatUint(uint64(cell), 16)
	return strings.Repeat("0", 7-len(key)) + key
}

func (p *poiIndex) features(ctx context.Context, z, x, y int) ([]VectorFeature, error) {
	if p == nil || z < 0 || z > 22 || x < 0 || y < 0 || x >= 1<<z || y >= 1<<z {
		return nil, nil
	}
	lookupZ, lookupX, lookupY := z, x, y
	if z > poiIndexZoom {
		lookupZ, lookupX, lookupY = poiIndexZoom, x>>(z-poiIndexZoom), y>>(z-poiIndexZoom)
	}
	shift := 2 * (poiIndexZoom - lookupZ)
	cell := poiCell(lookupX, lookupY, lookupZ)
	first, last := []byte(poiKey(cell<<shift)), []byte(poiKey(((cell+1)<<shift)-1))
	scratch := searchScratchPool.Get().(*searchScratch)
	defer searchScratchPool.Put(scratch)
	iterator, err := p.search.postingsFrom(first, scratch)
	if err != nil {
		return nil, err
	}
	records := searchRecords{search: p.search, ctx: ctx, scratch: scratch}
	scale := math.Exp2(float64(z))
	var features []VectorFeature
	seen := make(map[string]bool)
	for len(features) < maxTilePOIs {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		term, offset, length, err := iterator.next()
		if err == io.EOF {
			return features, nil
		}
		if err != nil {
			return nil, err
		}
		if bytes.Compare(term, first) < 0 {
			continue
		}
		if bytes.Compare(term, last) > 0 {
			return features, nil
		}
		data, err := records.read(offset, length)
		if err != nil {
			return nil, err
		}
		var record SearchResult
		if err := json.Unmarshal(data, &record); err != nil {
			return nil, err
		}
		if !validPOI(record) {
			continue
		}
		px, py := poiWorld(record)
		px, py = px*scale-float64(x), py*scale-float64(y)
		if px < 0 || px >= 1 || py < 0 || py >= 1 {
			continue
		}
		identity := fmt.Sprintf("%s/%d", record.Kind, record.ID)
		if seen[identity] {
			continue
		}
		seen[identity] = true
		features = append(features, VectorFeature{
			Layer: "poi", Kind: 1, Class: strings.TrimSpace(record.Category), Name: strings.TrimSpace(record.Label), Extent: 4096,
			Paths:          [][][2]int{{{min(4095, int(px*4096)), min(4095, int(py*4096))}}},
			SourceIdentity: identity, Details: cleanDetails(record.Details),
		})
	}
	return features, nil
}
