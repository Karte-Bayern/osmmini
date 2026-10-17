package osmmini

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

var graphStoreBenchmarkSum int64
var graphStoreBenchmarkCoords map[int64]Coord
var graphStoreBenchmarkAdj map[int64][]Edge

func benchmarkFileGraph(b *testing.B) *Router {
	b.Helper()
	r, _, _ := buildGridRouter(200, 200)
	path := filepath.Join(b.TempDir(), "graph.bin")
	if err := r.WriteGraph(context.Background(), path); err != nil {
		b.Fatal(err)
	}
	disk, err := OpenGraph(path)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = disk.Close() })
	return disk
}

func BenchmarkFileGraphScan(b *testing.B) {
	r := benchmarkFileGraph(b)
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		var sum int64
		r.g.eachNode(func(id int64, c Coord) { sum += id + int64(c.Lat) })
		graphStoreBenchmarkSum = sum
	}
}

func BenchmarkFileGraphCell(b *testing.B) {
	r := benchmarkFileGraph(b)
	x, y := r.idx.cell(48.08, 12.08)
	key := cellKey(x, y)
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		var sum int64
		for it := r.g.store.cellNodesIter(key); it.next(); {
			sum += it.nodeID()
		}
		graphStoreBenchmarkSum = sum
	}
}

func BenchmarkFileGraphExport(b *testing.B) {
	r := benchmarkFileGraph(b)
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		graphStoreBenchmarkCoords, graphStoreBenchmarkAdj = r.ExportGraph()
	}
}

func BenchmarkFileGraphRewrite(b *testing.B) {
	r := benchmarkFileGraph(b)
	path := filepath.Join(b.TempDir(), "graph-copy.bin")
	b.ReportAllocs()
	b.SetBytes(int64(len(r.g.store.data)))
	b.ResetTimer()
	for range b.N {
		if err := r.WriteGraph(context.Background(), path); err != nil {
			b.Fatal(err)
		}
		b.StopTimer()
		if err := os.Remove(path); err != nil {
			b.Fatal(err)
		}
		b.StartTimer()
	}
}

func BenchmarkMemoryGraphWrite(b *testing.B) {
	r, _, _ := buildGridRouter(200, 200)
	path := filepath.Join(b.TempDir(), "graph.bin")
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if err := r.WriteGraph(context.Background(), path); err != nil {
			b.Fatal(err)
		}
		b.StopTimer()
		if err := os.Remove(path); err != nil {
			b.Fatal(err)
		}
		b.StartTimer()
	}
}
