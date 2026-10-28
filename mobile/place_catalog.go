package mobile

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
)

const (
	placeCatalogFilename    = "places.jsonl"
	placeCatalogMagic       = "OSMMPL01"
	placeCatalogHeaderBytes = 24
	// JSON escaping can expand a previously accepted 64 KiB source record by
	// up to six times. Normal records stay in the small reader buffer.
	placeCatalogMaxRecordBytes = 6 * placeScanBufferBytes
)

// The fixed header contains a versioned magic, record count, payload CRC32 and
// four reserved zero bytes. Count and checksum detect truncated whole records
// as well as malformed JSON; publication never exposes a partially written file.
func writePlaceCatalog(ctx context.Context, path string, search *searchReader) error {
	return writePlaceCatalogFrom(ctx, path, func(visit func(SearchResult) error) error {
		return scanSearchPlaces(ctx, search, visit)
	})
}

func writePlaceCatalogFrom(ctx context.Context, path string, records func(func(SearchResult) error) error) (err error) {
	if err = ctx.Err(); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".places-*.tmp")
	if err != nil {
		return err
	}
	defer func() {
		file.Close()
		os.Remove(file.Name())
	}()
	var header [placeCatalogHeaderBytes]byte
	if _, err = file.Write(header[:]); err != nil {
		return err
	}
	checksum := crc32.NewIEEE()
	writer := bufio.NewWriterSize(io.MultiWriter(file, checksum), placeScanBufferBytes)
	encoder := json.NewEncoder(writer)
	var count uint64
	err = records(func(record SearchResult) error {
		record.Text = ""
		if err := encoder.Encode(record); err != nil {
			return err
		}
		count++
		return nil
	})
	if err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = writer.Flush(); err != nil {
		return err
	}
	copy(header[:8], placeCatalogMagic)
	binary.LittleEndian.PutUint64(header[8:16], count)
	binary.LittleEndian.PutUint32(header[16:20], checksum.Sum32())
	if _, err = file.WriteAt(header[:], 0); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func readPlaceCatalog(ctx context.Context, path string) (*placeCatalog, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var header [placeCatalogHeaderBytes]byte
	if _, err := io.ReadFull(file, header[:]); err != nil {
		return nil, fmt.Errorf("invalid place catalog header: %w", err)
	}
	if string(header[:8]) != placeCatalogMagic || binary.LittleEndian.Uint32(header[20:]) != 0 {
		return nil, fmt.Errorf("invalid place catalog version")
	}
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	count := binary.LittleEndian.Uint64(header[8:16])
	if count > uint64(info.Size()-placeCatalogHeaderBytes) {
		return nil, fmt.Errorf("invalid place catalog record count")
	}
	checksum := crc32.NewIEEE()
	reader := bufio.NewReaderSize(io.TeeReader(file, checksum), placeScanBufferBytes)
	index := &placeCatalog{labels: placeIndex{}, exact: exactPlaceIndex{}}
	var scratch []byte
	for range count {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		line, err := readPlaceCatalogLine(ctx, reader, &scratch)
		if err != nil {
			return nil, fmt.Errorf("invalid place catalog record: %w", err)
		}
		var record SearchResult
		if err := json.Unmarshal(line, &record); err != nil {
			return nil, fmt.Errorf("invalid place catalog record: %w", err)
		}
		if _, _, _, valid := settlementRecord(record); !valid || record.Text != "" {
			return nil, fmt.Errorf("invalid place catalog settlement")
		}
		index.add(record)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if _, err := reader.ReadByte(); !errors.Is(err, io.EOF) {
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("unexpected place catalog data")
	}
	if checksum.Sum32() != binary.LittleEndian.Uint32(header[16:20]) {
		return nil, fmt.Errorf("invalid place catalog checksum")
	}
	return index, nil
}

func readPlaceCatalogLine(ctx context.Context, reader *bufio.Reader, scratch *[]byte) ([]byte, error) {
	line, err := reader.ReadSlice('\n')
	if !errors.Is(err, bufio.ErrBufferFull) {
		return line, err
	}
	*scratch = append((*scratch)[:0], line...)
	for errors.Is(err, bufio.ErrBufferFull) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		line, err = reader.ReadSlice('\n')
		if len(*scratch)+len(line) > placeCatalogMaxRecordBytes {
			return nil, fmt.Errorf("place catalog record exceeds size limit")
		}
		*scratch = append(*scratch, line...)
	}
	return *scratch, err
}
