package mobile

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// Build the new index from an independently encoded legacy catalog, so query
// equivalence does not depend on both test paths using the same encoder.
func compactSearchCatalog(tb testing.TB, legacy string) string {
	tb.Helper()
	reader, err := openSearch(legacy)
	if err != nil {
		tb.Fatal(err)
	}
	defer reader.close()
	iterator, err := reader.postingsFrom(nil, new(searchScratch))
	if err != nil {
		tb.Fatal(err)
	}
	var postings []searchPosting
	for range reader.count {
		term, offset, length, err := iterator.next()
		if err != nil {
			tb.Fatal(err)
		}
		postings = append(postings, searchPosting{string(term), offset, length})
	}
	path := legacy + ".compact"
	data, err := os.ReadFile(legacy)
	if err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		tb.Fatal(err)
	}
	if err := writeSearchPostings(context.Background(), path+".idx", postings, false); err != nil {
		tb.Fatal(err)
	}
	return path
}

func TestCompactSearchPreservesLegacyQueriesAndOrder(t *testing.T) {
	results := make([]SearchResult, 1800)
	for i := range results {
		results[i] = SearchResult{ID: int64(i + 1), Kind: "node", Label: fmt.Sprintf("München Hauptstraße %04d", i), Category: "pharmacy"}
	}
	results = append(results,
		SearchResult{ID: 2001, Kind: "node", Label: "Café Cafeteria", Category: "cafe"},
		SearchResult{ID: 2002, Kind: "node", Label: "αθήνα 東京 ٢٣"},
		SearchResult{ID: 2003, Kind: "node", Label: strings.Repeat("x", searchKeyBytes+10)},
	)
	legacy := writeSearchCatalog(t, results)
	compact := compactSearchCatalog(t, legacy)
	old, err := openSearch(legacy)
	if err != nil {
		t.Fatal(err)
	}
	defer old.close()
	current, err := openSearch(compact)
	if err != nil {
		t.Fatal(err)
	}
	defer current.close()
	for _, query := range []string{"", "missing", "a", "apotheke", "mun", "munchen", "munch 0123", "0123 munch", "cafe", "αθή", "東京", "٢٣", strings.Repeat("x", searchKeyBytes), strings.Repeat("x", searchKeyBytes+1)} {
		for _, limit := range []int{-1, 1, 20, 100, 101} {
			want, err := old.search(t.Context(), query, limit)
			if err != nil {
				t.Fatal(err)
			}
			got, err := current.search(t.Context(), query, limit)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("%q limit %d differs: %+v, want %+v; %v", query, limit, got, want, err)
			}
		}
	}
	// Repeated terms span many blocks; searching from the earliest directory
	// match must not drop the first records or change offset ordering.
	for n := 0; n < len(results); n += 71 {
		query := fmt.Sprintf("munch %04d", n)
		want, err := old.search(t.Context(), query, 100)
		if err != nil {
			t.Fatal(err)
		}
		got, err := current.search(t.Context(), query, 100)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("%q differs: %+v, want %+v; %v", query, got, want, err)
		}
	}
	oldInfo, _ := os.Stat(legacy + ".idx")
	newInfo, _ := os.Stat(compact + ".idx")
	if newInfo.Size() >= oldInfo.Size()/8 {
		t.Fatalf("compact index grew unexpectedly: %d vs legacy %d bytes", newInfo.Size(), oldInfo.Size())
	}
	t.Logf("index: %d -> %d bytes", oldInfo.Size(), newInfo.Size())
}

func TestCompactSearchParallelQueriesAndCancellation(t *testing.T) {
	path := compactSearchCatalog(t, writeSearchCatalog(t, []SearchResult{
		{ID: 1, Kind: "node", Label: "Café Müller", Category: "cafe"},
		{ID: 2, Kind: "node", Label: "Apotheke Nord", Category: "pharmacy"},
		{ID: 3, Kind: "street", Label: "Hauptstraße"},
	}))
	reader, err := openSearch(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.close()
	var group sync.WaitGroup
	for range 16 {
		group.Go(func() {
			for range 30 {
				for _, query := range []string{"cafe", "apotheke", "haupt", "missing"} {
					got, err := reader.search(t.Context(), query, 20)
					want := map[string]int64{"cafe": 1, "apotheke": 2, "haupt": 3}[query]
					if err != nil || want == 0 && len(got) != 0 || want != 0 && (len(got) != 1 || got[0].ID != want) {
						t.Errorf("%q: %+v; %v", query, got, err)
						return
					}
				}
			}
		})
	}
	group.Wait()
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := reader.search(ctx, "cafe", 20); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled search = %v", err)
	}
}

func TestCompactSearchRejectsCorruptData(t *testing.T) {
	for _, tc := range []struct {
		name   string
		atOpen bool
		mutate func([]byte) []byte
	}{
		{"version", true, func(b []byte) []byte { b[8]++; return b }},
		{"header truncation", true, func(b []byte) []byte { return b[:20] }},
		{"directory bounds", true, func(b []byte) []byte { binary.LittleEndian.PutUint64(b[32:], ^uint64(0)); return b }},
		{"directory count", true, func(b []byte) []byte { binary.LittleEndian.PutUint64(b[16:], ^uint64(0)); return b }},
		{"posting count", true, func(b []byte) []byte { binary.LittleEndian.PutUint64(b[24:], ^uint64(0)); return b }},
		{"directory truncation", true, func(b []byte) []byte { return b[:len(b)-1] }},
		{"block offset", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			binary.LittleEndian.PutUint64(b[at+96:], ^uint64(0))
			return b
		}},
		{"block size", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			binary.LittleEndian.PutUint32(b[at+104:], searchBlockMaxBytes+1)
			return b
		}},
		{"block count", false, func(b []byte) []byte {
			at := binary.LittleEndian.Uint64(b[32:])
			binary.LittleEndian.PutUint32(b[at+108:], searchBlockPostings+1)
			return b
		}},
		{"term prefix", false, func(b []byte) []byte { b[searchCompactHeaderBytes] = searchKeyBytes; return b }},
		{"term suffix", false, func(b []byte) []byte { b[searchCompactHeaderBytes+1] = 255; return b }},
		{"directory key", false, func(b []byte) []byte { at := binary.LittleEndian.Uint64(b[32:]); b[at] = 'a'; return b }},
		{"truncated varint", false, func(b []byte) []byte { at := binary.LittleEndian.Uint64(b[32:]); b[at-1] = 255; return b }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := compactSearchCatalog(t, writeSearchCatalog(t, []SearchResult{{ID: 1, Kind: "node", Label: "Cafe"}}))
			b, err := os.ReadFile(path + ".idx")
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path+".idx", tc.mutate(b), 0o600); err != nil {
				t.Fatal(err)
			}
			reader, err := openSearch(path)
			if tc.atOpen {
				if err == nil {
					reader.close()
					t.Fatal("corrupt index opened")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer reader.close()
			if _, err = reader.search(t.Context(), "cafe", 10); err == nil {
				t.Fatal("corrupt posting accepted")
			}
		})
	}
}

func TestCompactSearchChecksRecordBounds(t *testing.T) {
	for _, offset := range []uint64{1 << 63, ^uint64(0)} {
		path := writeSearchCatalog(t, []SearchResult{{ID: 1, Kind: "node", Label: "Cafe"}})
		if err := writeSearchPostings(t.Context(), path+".idx", []searchPosting{{"cafe", offset, 10}}, false); err != nil {
			t.Fatal(err)
		}
		reader, err := openSearch(path)
		if err != nil {
			t.Fatal(err)
		}
		_, err = reader.search(t.Context(), "cafe", 20)
		reader.close()
		if err == nil {
			t.Fatalf("accepted offset %d", offset)
		}
	}
	for _, posting := range []searchPosting{{"cafe", 0, 0}, {"cafe", 0, maxSearchRecordBytes + 1}, {strings.Repeat("x", searchKeyBytes+1), 0, 1}} {
		directory := t.TempDir()
		path := directory + "/invalid.idx"
		if err := writeSearchPostings(t.Context(), path, []searchPosting{posting}, false); err == nil {
			t.Fatalf("accepted %+v", posting)
		}
		entries, err := os.ReadDir(directory)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), ".search-sort-") {
				t.Fatal("scratch retained")
			}
		}
	}
}

func TestCompactSearchPreservesPlaceLabels(t *testing.T) {
	legacy := writeSearchCatalog(t, []SearchResult{{ID: 1, Kind: "node", Label: "Landau", Category: "town", Place: "town"}})
	compact := compactSearchCatalog(t, legacy)
	old, err := openSearch(legacy)
	if err != nil {
		t.Fatal(err)
	}
	defer old.close()
	current, err := openSearch(compact)
	if err != nil {
		t.Fatal(err)
	}
	defer current.close()
	want, err := loadPlaces(t.Context(), old)
	if err != nil {
		t.Fatal(err)
	}
	got, err := loadPlaces(t.Context(), current)
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("place labels differ: %+v vs %+v; %v", got, want, err)
	}
	oldData, _ := os.ReadFile(legacy)
	newData, _ := os.ReadFile(compact)
	if !bytes.Equal(oldData, newData) {
		t.Fatal("search JSON records changed")
	}
}

func TestCompactSearchRejectsDecodedPostingOrder(t *testing.T) {
	posting := func(shared byte, suffix string, offset uint64) []byte {
		b := append([]byte{shared, byte(len(suffix))}, suffix...)
		b = binary.AppendUvarint(b, offset)
		return binary.AppendUvarint(b, 1)
	}
	repeated := func() []byte {
		b := posting(0, "a", 0)
		for n := 1; n < searchBlockPostings; n++ {
			b = append(b, posting(1, "", 1)...)
		}
		return b
	}
	prefixBlock := posting(0, "a", 0)
	for n := 1; n < searchBlockPostings-1; n++ {
		prefixBlock = append(prefixBlock, posting(1, "", 1)...)
	}
	prefixBlock = append(prefixBlock, posting(1, "bz", 0)...)
	for _, tc := range []struct {
		name   string
		blocks [][]byte
		first  []string
		count  int
		badAt  int
	}{
		{"full suffix", [][]byte{append(posting(0, "abz", 0), posting(0, "aby", 1)...)}, []string{"abz"}, 2, 1},
		{"shared suffix", [][]byte{append(posting(0, "abz", 0), posting(1, "by", 1)...)}, []string{"abz"}, 2, 1},
		{"next block term", [][]byte{prefixBlock, posting(0, "aby", 0)}, []string{"a", "aby"}, searchBlockPostings + 1, searchBlockPostings},
		{"next block offset", [][]byte{repeated(), posting(0, "a", 3)}, []string{"a", "a"}, searchBlockPostings + 1, searchBlockPostings},
		{"repeated noncanonical term", [][]byte{append(posting(0, "abz", 1), posting(0, "abz", 0)...)}, []string{"abz"}, 2, 1},
		{"offset overflow", [][]byte{append(posting(0, "a", ^uint64(0)), posting(1, "", 1)...)}, []string{"a"}, 2, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Encode directory and blocks independently of the production writer:
			// these malformed payloads satisfy the section/count bounds and have
			// sorted directory keys, but their decoded postings are not sorted.
			b := make([]byte, searchCompactHeaderBytes)
			var directory []byte
			for n, block := range tc.blocks {
				var entry [searchIndexBytes]byte
				copy(entry[:searchKeyBytes], tc.first[n])
				binary.LittleEndian.PutUint64(entry[96:], uint64(len(b)))
				binary.LittleEndian.PutUint32(entry[104:], uint32(len(block)))
				binary.LittleEndian.PutUint32(entry[108:], uint32(min(searchBlockPostings, tc.count-n*searchBlockPostings)))
				directory = append(directory, entry[:]...)
				b = append(b, block...)
			}
			copy(b[:8], searchCompactMagic)
			binary.LittleEndian.PutUint32(b[8:], 2)
			binary.LittleEndian.PutUint32(b[12:], searchBlockPostings)
			binary.LittleEndian.PutUint64(b[16:], uint64(len(tc.blocks)))
			binary.LittleEndian.PutUint64(b[24:], uint64(tc.count))
			binary.LittleEndian.PutUint64(b[32:], uint64(len(b)))
			binary.LittleEndian.PutUint32(b[40:], searchIndexBytes)
			b = append(b, directory...)
			path := t.TempDir() + "/invalid.idx"
			if err := os.WriteFile(path, b, 0o600); err != nil {
				t.Fatal(err)
			}
			file, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			reader := &searchReader{index: file}
			if err := reader.readIndexHeader(int64(len(b))); err != nil {
				t.Fatal(err)
			}
			iterator, err := reader.postingsFrom(nil, new(searchScratch))
			if err != nil {
				t.Fatal(err)
			}
			for n := 0; n <= tc.badAt; n++ {
				_, _, _, err := iterator.next()
				if n < tc.badAt && err != nil {
					t.Fatalf("posting %d failed early: %v", n, err)
				}
				if n == tc.badAt && err == nil {
					t.Fatalf("accepted unordered posting %d", n)
				}
			}
		})
	}
}
