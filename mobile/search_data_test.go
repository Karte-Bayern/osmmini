package mobile

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func writeCompressedSearchData(tb testing.TB, data []byte) string {
	tb.Helper()
	path := filepath.Join(tb.TempDir(), "search.jsonl")
	file, err := os.Create(path)
	if err != nil {
		tb.Fatal(err)
	}
	defer file.Close()
	writer, err := newSearchDataWriter(context.Background(), file)
	if err != nil {
		tb.Fatal(err)
	}
	defer writer.close()
	// Deliberately split JSON records and DEFLATE blocks across writes.
	for at := 0; at < len(data); at += 7093 {
		part := data[at:min(len(data), at+7093)]
		if n, err := writer.Write(part); err != nil || n != len(part) {
			tb.Fatalf("write = %d, %v", n, err)
		}
	}
	if err := writer.finish(); err != nil {
		tb.Fatal(err)
	}
	writer.close()
	if err := os.WriteFile(path+".idx", nil, 0o600); err != nil {
		tb.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		tb.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".search-") {
			tb.Fatalf("search data scratch remains: %s", entry.Name())
		}
	}
	return path
}

func compressedSearchCatalog(tb testing.TB, raw string) string {
	tb.Helper()
	data, err := os.ReadFile(raw)
	if err != nil {
		tb.Fatal(err)
	}
	path := writeCompressedSearchData(tb, data)
	index, err := os.ReadFile(raw + ".idx")
	if err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(path+".idx", index, 0o600); err != nil {
		tb.Fatal(err)
	}
	return path
}

func TestCompressedSearchDataRandomAndSequentialReads(t *testing.T) {
	random := rand.New(rand.NewPCG(1, 2))
	data := make([]byte, 2*maxSearchRecordBytes+719)
	for at := 0; at+8 <= len(data); at += 8 {
		binary.LittleEndian.PutUint64(data[at:], random.Uint64())
	}
	path := writeCompressedSearchData(t, data)
	reader, err := openSearch(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.close()
	if !reader.compressedData || reader.dataBytes != int64(len(data)) {
		t.Fatalf("wrong logical data size: %+v", reader)
	}
	records := searchRecords{search: reader, ctx: t.Context(), scratch: new(searchScratch)}
	for _, span := range [][2]int{
		{0, 1}, {1, searchDataBlockBytes - 1}, {searchDataBlockBytes - 3, 17},
		{7, maxSearchRecordBytes}, {maxSearchRecordBytes, maxSearchRecordBytes},
		{len(data) - 1, 1}, {0, searchDataBlockBytes}, {8, 17},
	} {
		got, err := records.read(uint64(span[0]), uint32(span[1]))
		if err != nil || !bytes.Equal(got, data[span[0]:span[0]+span[1]]) {
			t.Fatalf("read %v differs: %v", span, err)
		}
	}
	for _, span := range [][2]uint64{{0, 0}, {0, maxSearchRecordBytes + 1}, {uint64(len(data)), 1}, {^uint64(0), 2}} {
		if _, err := records.read(span[0], uint32(span[1])); err == nil {
			t.Fatalf("invalid span %v accepted", span)
		}
	}
	if _, err := reader.data.Seek(13, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	stream := &searchDataStream{search: reader, ctx: t.Context(), scratch: new(searchScratch)}
	got, err := io.ReadAll(stream)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("sequential read differs: %v", err)
	}
	if cursor, err := reader.data.Seek(0, io.SeekCurrent); err != nil || cursor != 13 {
		t.Fatalf("sequential scan changed file cursor: %d, %v", cursor, err)
	}
}

func TestCompressedSearchDataEmptyAndExactBlocks(t *testing.T) {
	for _, size := range []int{0, 1, searchDataBlockBytes, 2 * searchDataBlockBytes} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			data := bytes.Repeat([]byte("x"), size)
			reader, err := openSearch(writeCompressedSearchData(t, data))
			if err != nil {
				t.Fatal(err)
			}
			defer reader.close()
			got, err := io.ReadAll(&searchDataStream{search: reader, ctx: t.Context(), scratch: new(searchScratch)})
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("size %d differs: %v", size, err)
			}
		})
	}
}

func TestCompressedSearchPreservesQueriesAndPlaces(t *testing.T) {
	results := []SearchResult{
		{ID: 1, Kind: "node", Label: "Before city", Category: "city", Place: "city"},
		{ID: 2, Kind: "street", Label: "Oversized street", Text: strings.Repeat("x", 512<<10)},
		{ID: 3, Kind: "node", Label: "After town", Place: "town"},
		{ID: 4, Kind: "node", Label: "Café Müller 東京 ٢٣", Category: "cafe"},
	}
	for i := range 900 {
		results = append(results, SearchResult{ID: int64(i + 5), Kind: "node", Label: fmt.Sprintf("München Hauptstraße %04d", i), Category: "pharmacy"})
	}
	legacy := writeSearchCatalog(t, results)
	old, err := openSearch(legacy)
	if err != nil {
		t.Fatal(err)
	}
	defer old.close()
	wantPlaces, err := loadPlaces(t.Context(), old)
	if err != nil {
		t.Fatal(err)
	}
	for name, raw := range map[string]string{"legacy index": legacy, "compact index": compactSearchCatalog(t, legacy)} {
		t.Run(name, func(t *testing.T) {
			path := compressedSearchCatalog(t, raw)
			reader, err := openSearch(path)
			if err != nil {
				t.Fatal(err)
			}
			defer reader.close()
			for _, query := range []string{"", "missing", "apotheke", "munch", "munchen", "munch 0123", "0123 munch", "cafe", "東京", "٢٣", "before", "after", "oversized", strings.Repeat("x", searchKeyBytes)} {
				for _, limit := range []int{-1, 1, 20, 100, 101} {
					want, err := old.search(t.Context(), query, limit)
					if err != nil {
						t.Fatal(err)
					}
					got, err := reader.search(t.Context(), query, limit)
					if err != nil || !reflect.DeepEqual(got, want) {
						t.Fatalf("%q limit %d differs: %+v, want %+v; %v", query, limit, got, want, err)
					}
				}
			}
			if _, err := reader.data.Seek(13, io.SeekStart); err != nil {
				t.Fatal(err)
			}
			gotPlaces, err := loadPlaces(t.Context(), reader)
			if err != nil || !reflect.DeepEqual(gotPlaces, wantPlaces) {
				t.Fatalf("place labels differ: %+v, want %+v; %v", gotPlaces, wantPlaces, err)
			}
			if cursor, err := reader.data.Seek(0, io.SeekCurrent); err != nil || cursor != 13 {
				t.Fatalf("place scan changed file cursor: %d, %v", cursor, err)
			}
			oldInfo, _ := os.Stat(raw)
			newInfo, _ := os.Stat(path)
			if newInfo.Size() >= oldInfo.Size()/4 {
				t.Fatalf("catalog compression ineffective: %d vs %d bytes", newInfo.Size(), oldInfo.Size())
			}
		})
	}
}

func TestCompressedSearchConcurrentReadsAndCancellation(t *testing.T) {
	path := compressedSearchCatalog(t, compactSearchCatalog(t, writeSearchCatalog(t, []SearchResult{
		{ID: 1, Kind: "node", Label: "Landau", Category: "town", Place: "town"},
		{ID: 2, Kind: "street", Label: "Hauptstraße", Text: strings.Repeat("x", 128<<10)},
	})))
	reader, err := openSearch(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.close()
	var group sync.WaitGroup
	for range 8 {
		group.Go(func() {
			for range 10 {
				for _, query := range []string{"landau", "haupt"} {
					got, err := reader.search(t.Context(), query, 20)
					if err != nil || len(got) != 1 {
						t.Errorf("concurrent query %q: %+v, %v", query, got, err)
						return
					}
				}
				places, err := loadPlaces(t.Context(), reader)
				if err != nil || len(places) != 1 {
					t.Errorf("concurrent place scan: %+v, %v", places, err)
					return
				}
			}
		})
	}
	group.Wait()
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := reader.search(ctx, "landau", 20); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled query = %v", err)
	}
	if _, err := loadPlaces(ctx, reader); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled place scan = %v", err)
	}
	ctx, cancel = context.WithCancel(t.Context())
	defer cancel()
	duringScan := &cancelPlaceScanContext{Context: ctx, cancel: cancel}
	if _, err := loadPlaces(duringScan, reader); !errors.Is(err, context.Canceled) {
		t.Fatalf("place scan cancellation between blocks = %v", err)
	}
	ctx, cancel = context.WithCancel(t.Context())
	defer cancel()
	duringRecord := &cancelPlaceScanContext{Context: ctx, cancel: cancel}
	records := searchRecords{search: reader, ctx: duringRecord, scratch: new(searchScratch)}
	if _, err := records.read(0, 100<<10); !errors.Is(err, context.Canceled) {
		t.Fatalf("large record cancellation between blocks = %v", err)
	}
	file, err := os.Create(filepath.Join(t.TempDir(), "cancelled"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer, err := newSearchDataWriter(ctx, file)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.close()
	if _, err := writer.Write([]byte("x")); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled write = %v", err)
	}
	if err := writer.finish(); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled finish = %v", err)
	}
}

func TestCompressedSearchRejectsMalformedStorage(t *testing.T) {
	path := writeCompressedSearchData(t, bytes.Repeat([]byte("abcdefgh"), searchDataBlockBytes/4))
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		atOpen bool
		mutate func([]byte) []byte
	}{
		{"header truncation", true, func(b []byte) []byte { return b[:24] }},
		{"version", true, func(b []byte) []byte { b[8]++; return b }},
		{"block bytes", true, func(b []byte) []byte { b[12]++; return b }},
		{"logical overflow", true, func(b []byte) []byte { binary.LittleEndian.PutUint64(b[16:], ^uint64(0)); return b }},
		{"block count", true, func(b []byte) []byte { b[24]++; return b }},
		{"directory offset", true, func(b []byte) []byte { binary.LittleEndian.PutUint64(b[32:], ^uint64(0)); return b }},
		{"entry size", true, func(b []byte) []byte { b[40]++; return b }},
		{"reserved header", true, func(b []byte) []byte { b[44]++; return b }},
		{"directory truncation", true, func(b []byte) []byte { return b[:len(b)-1] }},
		{"block offset", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			binary.LittleEndian.PutUint64(b[at:], ^uint64(0))
			return b
		}},
		{"encoded overflow", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			binary.LittleEndian.PutUint32(b[at+8:], searchDataMaxEncoded+1)
			return b
		}},
		{"zero encoded size", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			binary.LittleEndian.PutUint32(b[at+8:], 0)
			return b
		}},
		{"reserved entry", false, func(b []byte) []byte { at := binary.LittleEndian.Uint64(b[32:]); b[at+12]++; return b }},
		{"noncontiguous blocks", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			b[at+searchDataEntryBytes]++
			return b
		}},
		{"zlib header", false, func(b []byte) []byte { b[searchDataHeaderBytes] = 0; return b }},
		{"checksum", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			size := binary.LittleEndian.Uint32(b[at+8:])
			b[searchDataHeaderBytes+size-1]++
			return b
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mutated := tc.mutate(bytes.Clone(original))
			if err := os.WriteFile(path, mutated, 0o600); err != nil {
				t.Fatal(err)
			}
			reader, err := openSearch(path)
			if tc.atOpen {
				if err == nil {
					reader.close()
					t.Fatal("malformed header accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer reader.close()
			if _, err := io.Copy(io.Discard, &searchDataStream{search: reader, ctx: t.Context(), scratch: new(searchScratch)}); err == nil {
				t.Fatal("malformed block accepted")
			}
		})
	}
}

func TestCompressedSearchRejectsExcessExpansionAndTrailingStreams(t *testing.T) {
	for _, mode := range []string{"excess expansion", "short expansion", "second zlib stream", "trailing byte"} {
		t.Run(mode, func(t *testing.T) {
			var encoded bytes.Buffer
			writer := zlib.NewWriter(&encoded)
			length := searchDataBlockBytes
			if mode == "excess expansion" {
				length++
			}
			if mode == "short expansion" {
				length--
			}
			writer.Write(make([]byte, length))
			writer.Close()
			if mode == "second zlib stream" {
				encoded.Write(bytes.Clone(encoded.Bytes()))
			}
			if mode == "trailing byte" {
				encoded.WriteByte(0)
			}
			header := make([]byte, searchDataHeaderBytes)
			copy(header, searchDataMagic)
			binary.LittleEndian.PutUint32(header[8:], 1)
			binary.LittleEndian.PutUint32(header[12:], searchDataBlockBytes)
			binary.LittleEndian.PutUint64(header[16:], searchDataBlockBytes)
			binary.LittleEndian.PutUint64(header[24:], 1)
			binary.LittleEndian.PutUint64(header[32:], uint64(len(header)+encoded.Len()))
			binary.LittleEndian.PutUint32(header[40:], searchDataEntryBytes)
			var entry [searchDataEntryBytes]byte
			binary.LittleEndian.PutUint64(entry[:], searchDataHeaderBytes)
			binary.LittleEndian.PutUint32(entry[8:], uint32(encoded.Len()))
			data := append(append(header, encoded.Bytes()...), entry[:]...)
			path := filepath.Join(t.TempDir(), "invalid")
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path+".idx", nil, 0o600); err != nil {
				t.Fatal(err)
			}
			reader, err := openSearch(path)
			if err != nil {
				t.Fatal(err)
			}
			defer reader.close()
			if _, err := reader.readDataBlock(t.Context(), 0, new(searchScratch)); err == nil {
				t.Fatalf("%s accepted", mode)
			}
		})
	}
}
