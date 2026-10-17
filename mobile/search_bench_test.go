package mobile

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// A synthetic regional catalog keeps performance measurements independent of PBF
// decoding and the operating system's file cache for large map packages.
func writeSearchCatalog(tb testing.TB, results []SearchResult) string {
	tb.Helper()
	path := filepath.Join(tb.TempDir(), "search.jsonl")
	var data []byte
	var postings []searchPosting
	for _, result := range results {
		result.Text = normalized(result.Text + " " + result.Label + " " + result.Category)
		b, err := json.Marshal(result)
		if err != nil {
			tb.Fatal(err)
		}
		b = append(b, '\n')
		seen := map[string]bool{}
		for _, word := range strings.Fields(result.Text) {
			if len(word) > searchKeyBytes {
				word = word[:searchKeyBytes]
			}
			if !seen[word] {
				postings = append(postings, searchPosting{word, uint64(len(data)), uint32(len(b))})
				seen[word] = true
			}
		}
		data = append(data, b...)
	}
	sort.Slice(postings, func(i, j int) bool {
		if postings[i].term != postings[j].term {
			return postings[i].term < postings[j].term
		}
		return postings[i].offset < postings[j].offset
	})
	index := make([]byte, len(postings)*searchIndexBytes)
	for i, posting := range postings {
		b := index[i*searchIndexBytes:][:searchIndexBytes]
		copy(b, posting.term)
		binary.LittleEndian.PutUint64(b[96:], posting.offset)
		binary.LittleEndian.PutUint32(b[104:], posting.length)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(path+".idx", index, 0o600); err != nil {
		tb.Fatal(err)
	}
	return path
}

func BenchmarkMobileSearch(b *testing.B) {
	results := make([]SearchResult, 20_000)
	for i := range results {
		results[i] = SearchResult{ID: int64(i + 1), Kind: "node", Label: fmt.Sprintf("Apotheke München %05d", i), Category: "pharmacy"}
	}
	path := writeSearchCatalog(b, results)
	s, err := openSearch(path)
	if err != nil {
		b.Fatal(err)
	}
	defer s.close()
	for _, query := range []string{"Apotheke", "munch 12345", "missing"} {
		b.Run(query, func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, err := s.search(context.Background(), query, 20); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkMobileNormalize(b *testing.B) {
	for _, input := range []string{"already clean cafe 42", "Café Müller · München Hauptstraße 7"} {
		b.Run(input, func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				_ = normalized(input)
			}
		})
	}
}
