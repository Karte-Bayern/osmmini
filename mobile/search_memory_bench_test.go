package mobile

import (
	"context"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Peak-live-B measures the objects actually retained while building a regional
// catalog, rather than cumulative allocations. GC sampling is excluded from the
// elapsed benchmark time; run with -benchtime=1x for a quick before/after check.
func BenchmarkSearchIndexBuildMemory(b *testing.B) {
	for _, bounded := range []bool{false, true} {
		name := "retained-postings"
		if bounded {
			name = "bounded-sort"
		}
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			root := b.TempDir()
			var peak uint64
			for n := 0; n < b.N; n++ {
				b.StopTimer()
				runtime.GC()
				var baseline runtime.MemStats
				runtime.ReadMemStats(&baseline)
				path := filepath.Join(root, fmt.Sprintf("index-%d", n))
				builder := searchIndexBuilder{ctx: context.Background(), path: path}
				var postings []searchPosting
				sample := func() {
					b.StopTimer()
					runtime.GC()
					var current runtime.MemStats
					runtime.ReadMemStats(&current)
					if current.HeapAlloc > baseline.HeapAlloc {
						peak = max(peak, current.HeapAlloc-baseline.HeapAlloc)
					}
					runtime.KeepAlive(builder.postings)
					runtime.KeepAlive(postings)
					b.StartTimer()
				}
				b.StartTimer()
				for i := 0; i < 250_000; i++ {
					text := fmt.Sprintf("street%06d district%06d", 250_000-i, i%1297)
					for _, term := range strings.Fields(text) {
						p := searchPosting{term: term, offset: uint64(i) * 200, length: 200}
						if bounded {
							if err := builder.add(p); err != nil {
								b.Fatal(err)
							}
						} else {
							postings = append(postings, p)
						}
					}
					if i%8192 == 8190 {
						sample()
					}
				}
				sample()
				if bounded {
					if err := builder.finish(); err != nil {
						b.Fatal(err)
					}
					builder.close()
				} else {
					sortSearchPostings(postings)
					if err := writeSearchPostings(context.Background(), path, postings, false); err != nil {
						b.Fatal(err)
					}
				}
			}
			b.ReportMetric(float64(peak), "peak-live-B")
		})
	}
}
