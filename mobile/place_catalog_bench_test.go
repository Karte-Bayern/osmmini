package mobile

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func benchmarkPlaceCatalog(b *testing.B, source string) {
	b.Helper()
	search, err := openSearch(source)
	if err != nil {
		b.Fatal(err)
	}
	defer search.close()
	path := filepath.Join(b.TempDir(), placeCatalogFilename)
	if err := writePlaceCatalog(context.Background(), path, search); err != nil {
		b.Fatal(err)
	}
	for _, kind := range []string{"search-scan", "settlement-sidecar"} {
		b.Run(kind, func(b *testing.B) {
			b.ReportAllocs()
			for range b.N {
				var err error
				if kind == "search-scan" {
					_, err = loadPlaceCatalog(context.Background(), search)
				} else {
					_, err = readPlaceCatalog(context.Background(), path)
				}
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkPlaceCatalog(b *testing.B) {
	path := filepath.Join(b.TempDir(), "search.jsonl")
	file, err := os.Create(path)
	if err != nil {
		b.Fatal(err)
	}
	writer := bufio.NewWriter(file)
	encoder := json.NewEncoder(writer)
	text := strings.Repeat("irrelevant search terms ", 8)
	for i := range 100_000 {
		record := SearchResult{ID: int64(i + 1), Kind: "node", Label: fmt.Sprintf("POI %06d", i), Category: "cafe", Text: text}
		if i%100 == 0 {
			record.Label = fmt.Sprintf("Town %04d", i/100)
			record.Place = "town"
		}
		if err := encoder.Encode(record); err != nil {
			b.Fatal(err)
		}
	}
	if err := writer.Flush(); err != nil {
		b.Fatal(err)
	}
	if err := file.Close(); err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(path+".idx", nil, 0o600); err != nil {
		b.Fatal(err)
	}
	for _, format := range []string{"legacy", "compressed"} {
		source := path
		if format == "compressed" {
			source = compressedSearchCatalog(b, path)
		}
		b.Run(format, func(b *testing.B) { benchmarkPlaceCatalog(b, source) })
	}
}

func BenchmarkRealPlaceCatalog(b *testing.B) {
	region := os.Getenv("OSMMINI_REAL_REGION")
	if region == "" {
		b.Skip("set OSMMINI_REAL_REGION to a local imported region")
	}
	benchmarkPlaceCatalog(b, filepath.Join(region, "search.jsonl"))
}
