package mobile

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"unicode"

	osm "simonwaldherr.de/go/osmmini"
)

// SearchResult uses OSM IDs as signed 64-bit integers throughout the bridge.
type SearchResult struct {
	ID         int64     `json:"id"`
	Kind       string    `json:"kind"`
	Label      string    `json:"label"`
	Coordinate osm.Coord `json:"coordinate"`
	Category   string    `json:"category,omitempty"`
	Text       string    `json:"text,omitempty"`
}

const searchKeyBytes = 96
const searchIndexBytes = 112

type searchPosting struct {
	term   string
	offset uint64
	length uint32
}

func normalized(s string) string {
	// Most prefix queries are already lowercase ASCII. Return their existing
	// storage instead of allocating a replacer, token slice and joined string.
	clean := len(s) > 0 && s[0] != ' ' && s[len(s)-1] != ' '
	for i := 0; clean && i < len(s); i++ {
		c := s[i]
		clean = c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == ' ' && (i == 0 || s[i-1] != ' ')
	}
	if clean {
		return s
	}
	var out strings.Builder
	out.Grow(len(s))
	separator := false
	for _, r := range s {
		r = unicode.ToLower(r)
		switch r {
		case 'ä':
			r = 'a'
		case 'ö':
			r = 'o'
		case 'ü':
			r = 'u'
		case 'é':
			r = 'e'
		}
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			separator = out.Len() > 0
			continue
		}
		if separator {
			out.WriteByte(' ')
			separator = false
		}
		if r == 'ß' {
			out.WriteString("ss")
		} else {
			out.WriteRune(r)
		}
	}
	return out.String()
}

func buildSearch(ctx context.Context, path string, r *osm.Router, source string) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	var postings []searchPosting
	var offset uint64
	emit := func(result SearchResult) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		result.Text = normalized(result.Text + " " + result.Label + " " + result.Category)
		b, err := json.Marshal(result)
		if err != nil {
			return err
		}
		b = append(b, '\n')
		if _, err = w.Write(b); err != nil {
			return err
		}
		seen := map[string]bool{}
		for _, term := range strings.Fields(result.Text) {
			if len(term) > searchKeyBytes {
				term = term[:searchKeyBytes]
			}
			if !seen[term] {
				postings = append(postings, searchPosting{term, offset, uint32(len(b))})
				seen[term] = true
			}
		}
		offset += uint64(len(b))
		return nil
	}
	for _, street := range r.AllStreets() {
		if err = emit(SearchResult{ID: street.NodeID, Kind: "street", Label: street.Name, Coordinate: street.Coord}); err != nil {
			return err
		}
	}
	var ways []osm.Way
	refs := map[int64]osm.Coord{}
	poiKey := func(k string) bool {
		switch k {
		case "amenity", "shop", "tourism", "leisure", "office", "emergency", "place":
			return true
		}
		return false
	}
	category := func(tags osm.Tags) string {
		for _, k := range []string{"amenity", "shop", "tourism", "leisure", "office", "emergency", "place"} {
			if v := tags[k]; v != "" {
				return v
			}
		}
		return ""
	}
	result := func(id int64, kind string, c osm.Coord, tags osm.Tags) SearchResult {
		label := strings.TrimSpace(tags["name"])
		address := strings.TrimSpace(tags["addr:street"] + " " + tags["addr:housenumber"])
		if label == "" {
			label = address
		}
		if label == "" {
			label = category(tags)
		}
		if city := tags["addr:city"]; city != "" {
			label += " · " + city
		}
		return SearchResult{ID: id, Kind: kind, Label: label, Coordinate: c, Category: category(tags), Text: address + " " + tags["addr:postcode"] + " " + tags["brand"]}
	}
	opts := osm.Options{Context: ctx, EmitWayNodeIDs: true, TaggedWayKey: func(k string) bool { return poiKey(k) || strings.HasPrefix(k, "addr:") }, KeepTag: func(k string) bool { return k == "name" || k == "brand" || poiKey(k) || strings.HasPrefix(k, "addr:") }}
	err = osm.ExtractFile(source, opts, osm.Callbacks{TaggedNode: func(n osm.Node) error {
		if category(n.Tags) == "" && n.Tags["addr:street"] == "" {
			return nil
		}
		return emit(result(n.ID, "node", osm.Coord{Lat: n.Lat, Lon: n.Lon}, n.Tags))
	}, TaggedWay: func(way osm.Way) error {
		if category(way.Tags) == "" && way.Tags["addr:street"] == "" {
			return nil
		}
		ways = append(ways, way)
		for _, id := range way.NodeIDs {
			refs[id] = osm.Coord{}
		}
		return nil
	}})
	if err != nil {
		return err
	}
	if len(refs) > 0 {
		err = osm.ExtractFile(source, osm.Options{Context: ctx}, osm.Callbacks{Node: func(id int64, lat, lon float64) error {
			if _, ok := refs[id]; ok {
				refs[id] = osm.Coord{Lat: lat, Lon: lon}
			}
			return nil
		}})
		if err != nil {
			return err
		}
	}
	for _, way := range ways {
		var c osm.Coord
		count := 0
		for _, id := range way.NodeIDs {
			p := refs[id]
			if p.Lat != 0 || p.Lon != 0 {
				c.Lat += p.Lat
				c.Lon += p.Lon
				count++
			}
		}
		if count > 0 {
			c.Lat /= float64(count)
			c.Lon /= float64(count)
			if err = emit(result(way.ID, "way", c, way.Tags)); err != nil {
				return err
			}
		}
	}
	if err = w.Flush(); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	sort.Slice(postings, func(i, j int) bool {
		if postings[i].term != postings[j].term {
			return postings[i].term < postings[j].term
		}
		return postings[i].offset < postings[j].offset
	})
	index, err := os.OpenFile(path+".idx", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer index.Close()
	iw := bufio.NewWriter(index)
	var b [searchIndexBytes]byte
	for i, p := range postings {
		if i%4096 == 0 {
			if err = ctx.Err(); err != nil {
				return err
			}
		}
		clear(b[:])
		copy(b[:searchKeyBytes], p.term)
		binary.LittleEndian.PutUint64(b[96:], p.offset)
		binary.LittleEndian.PutUint32(b[104:], p.length)
		if _, err = iw.Write(b[:]); err != nil {
			return err
		}
	}
	if err = iw.Flush(); err != nil {
		return err
	}
	return index.Sync()
}

type searchReader struct {
	data, index *os.File
	count       int
	dataBytes   int64
}

// Scratch buffers are owned by one query and reused across calls. The reader
// itself has no cursor or mutable cache, so parallel Swift/Go searches cannot
// interfere with one another. Large JSON records are never retained by the pool.
type searchScratch struct {
	postings [64 * searchIndexBytes]byte
	data     [32 << 10]byte
}

var searchScratchPool = sync.Pool{New: func() any { return new(searchScratch) }}

func openSearch(path string) (*searchReader, error) {
	data, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	idx, err := os.Open(path + ".idx")
	if err != nil {
		data.Close()
		return nil, err
	}
	st, err := idx.Stat()
	if err != nil || st.Size()%searchIndexBytes != 0 {
		data.Close()
		idx.Close()
		return nil, fmt.Errorf("invalid search index")
	}
	dst, err := data.Stat()
	if err != nil {
		data.Close()
		idx.Close()
		return nil, err
	}
	return &searchReader{data: data, index: idx, count: int(st.Size() / searchIndexBytes), dataBytes: dst.Size()}, nil
}
func (s *searchReader) close() { s.data.Close(); s.index.Close() }
func (s *searchReader) search(ctx context.Context, query string, limit int) ([]SearchResult, error) {
	aliases := map[string]string{"apotheke": "pharmacy", "tankstelle": "fuel", "krankenhaus": "hospital", "supermarkt": "supermarket", "feuerwehr": "fire_station"}
	query = normalized(query)
	if alias := aliases[query]; alias != "" {
		query = normalized(alias)
	}
	words := strings.Fields(query)
	if len(words) == 0 {
		return []SearchResult{}, nil
	}
	if limit < 1 || limit > 100 {
		limit = 20
	}
	key := words[0]
	for _, word := range words {
		if len(word) > len(key) {
			key = word
		}
	}
	if len(key) > searchKeyBytes {
		return []SearchResult{}, nil
	}
	scratch := searchScratchPool.Get().(*searchScratch)
	defer searchScratchPool.Put(scratch)
	keyBytes := []byte(key)
	var readErr error
	start := sort.Search(s.count, func(i int) bool {
		b := scratch.postings[:searchIndexBytes]
		if _, err := s.index.ReadAt(b, int64(i)*searchIndexBytes); err != nil {
			readErr = err
			return true
		}
		term := b[:searchKeyBytes]
		if end := bytes.IndexByte(term, 0); end >= 0 {
			term = term[:end]
		}
		return bytes.Compare(term, keyBytes) >= 0
	})
	if readErr != nil {
		return nil, readErr
	}
	seen := map[uint64]bool{}
	out := []SearchResult{}
	var dataStart, dataEnd uint64
	var oversized []byte
	readRecord := func(offset uint64, length uint32) ([]byte, error) {
		if length > 1<<20 || offset > uint64(s.dataBytes) || uint64(length) > uint64(s.dataBytes)-offset {
			return nil, fmt.Errorf("invalid search record length or offset")
		}
		end := offset + uint64(length)
		if offset >= dataStart && end <= dataEnd {
			return scratch.data[offset-dataStart : end-dataStart], nil
		}
		if length > uint32(len(scratch.data)) {
			if cap(oversized) < int(length) {
				oversized = make([]byte, length)
			}
			b := oversized[:length]
			_, err := s.data.ReadAt(b, int64(offset))
			return b, err
		}
		n := min(len(scratch.data), int(uint64(s.dataBytes)-offset))
		if _, err := s.data.ReadAt(scratch.data[:n], int64(offset)); err != nil {
			return nil, err
		}
		dataStart, dataEnd = offset, offset+uint64(n)
		return scratch.data[:length], nil
	}
	for i := start; i < s.count && len(out) < limit; {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		n := min(len(scratch.postings)/searchIndexBytes, s.count-i)
		batch := scratch.postings[:n*searchIndexBytes]
		if _, err := s.index.ReadAt(batch, int64(i)*searchIndexBytes); err != nil {
			return nil, err
		}
		for j := 0; j < n && len(out) < limit; j++ {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			p := batch[j*searchIndexBytes:][:searchIndexBytes]
			if !bytes.HasPrefix(p[:searchKeyBytes], keyBytes) {
				return out, nil
			}
			i++
			offset := binary.LittleEndian.Uint64(p[96:])
			b, err := readRecord(offset, binary.LittleEndian.Uint32(p[104:]))
			if err != nil {
				return nil, err
			}
			// Normalized words contain only letters/digits and therefore have no
			// JSON escape sequences. A missing raw word cannot match Text. This
			// cheap filter avoids decoding every POI for a broad prefix; the full
			// Text check below retains the established substring semantics.
			matches := true
			for _, word := range words {
				if !bytes.Contains(b, []byte(word)) {
					matches = false
					break
				}
			}
			if !matches {
				continue
			}
			if seen[offset] {
				continue
			}
			seen[offset] = true
			var result SearchResult
			if err = json.Unmarshal(b, &result); err != nil {
				return nil, err
			}
			for _, word := range words {
				if !strings.Contains(result.Text, word) {
					matches = false
					break
				}
			}
			if matches {
				result.Text = ""
				if len(out) == 0 {
					out = make([]SearchResult, 0, limit)
				}
				out = append(out, result)
			}
		}
	}
	return out, nil
}
