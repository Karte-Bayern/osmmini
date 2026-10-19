package osmmini

import (
	"os"
	"path/filepath"
	"testing"
)

var benchmarkImportedRouter *Router

// A road grid keeps parser work fixed while exposing adjacency allocations for
// many small node degrees, the common shape of a full-region road graph.
func BenchmarkRoadGraphImport(b *testing.B) {
	const width, height = 200, 200
	var nodes, ways []byte
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			id := int64(y*width + x + 1)
			nodes = append(nodes, testPBFPrimitiveGroup(1, testPBFNode(id, nil, nil, 480000000+int64(y)*10000, 120000000+int64(x)*10000))...)
		}
	}
	for y := 0; y < height; y++ {
		refs := make([]int64, width)
		refs[0] = int64(y*width + 1)
		for x := 1; x < width; x++ {
			refs[x] = 1
		}
		ways = append(ways, testPBFPrimitiveGroup(3, testPBFWay(int64(y+1), []uint64{1}, []uint64{2}, refs))...)
	}
	for x := 0; x < width; x++ {
		refs := make([]int64, height)
		refs[0] = int64(x + 1)
		for y := 1; y < height; y++ {
			refs[y] = width
		}
		ways = append(ways, testPBFPrimitiveGroup(3, testPBFWay(int64(height+x+1), []uint64{1}, []uint64{2}, refs))...)
	}
	data := append(testPBFData([]string{""}, nodes), testPBFData([]string{"", "highway", "residential"}, ways)...)
	path := filepath.Join(b.TempDir(), "grid.osm.pbf")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		router, _, err := BuildRouterWithAddressesOptions(path, BuildOptions{Context: b.Context(), MaxNodes: width * height, SkipAddresses: true})
		if err != nil {
			b.Fatal(err)
		}
		if router.NodeCount() != width*height || router.EdgeCount() != 2*((width-1)*height+(height-1)*width) {
			b.Fatal("incomplete benchmark graph")
		}
		benchmarkImportedRouter = router
	}
}
