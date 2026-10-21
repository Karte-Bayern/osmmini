package mobile

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// Isolate posting scans from JSON decoding and data-block decompression.
func BenchmarkSearchPostingScan(b *testing.B) {
	postings := make([]searchPosting, 128_000)
	for i := range postings {
		postings[i] = searchPosting{fmt.Sprintf("term%06d", i/8), uint64(i) * 160, 160}
	}
	path := filepath.Join(b.TempDir(), "search.idx")
	if err := writeSearchPostings(context.Background(), path, postings, false); err != nil {
		b.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		b.Fatal(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		b.Fatal(err)
	}
	reader := &searchReader{index: file}
	if err := reader.readIndexHeader(info.Size()); err != nil {
		b.Fatal(err)
	}
	scratch := new(searchScratch)
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		iterator, err := reader.postingsFrom([]byte("term"), scratch)
		if err != nil {
			b.Fatal(err)
		}
		count := 0
		for {
			_, _, _, err := iterator.next()
			if err == io.EOF {
				break
			}
			if err != nil {
				b.Fatal(err)
			}
			count++
		}
		if count != len(postings) {
			b.Fatalf("read %d of %d postings", count, len(postings))
		}
	}
}
