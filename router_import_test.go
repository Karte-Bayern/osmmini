package osmmini

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func roadImportFixture(t *testing.T) string {
	t.Helper()
	table := []string{"", "highway", "residential", "name", "Teststraße", "oneway", "yes", "addr:street", "Nebenstraße", "addr:housenumber", "9", "access", "no"}
	// Put ways before nodes: the importer must not rely on PBF entity order.
	var ways []byte
	ways = append(ways, testPBFPrimitiveGroup(3, testPBFWay(1, []uint64{1, 3, 5}, []uint64{2, 4, 6}, []int64{10, 10, 10, 60}))...)
	ways = append(ways, testPBFPrimitiveGroup(3, testPBFWay(2, []uint64{1, 11}, []uint64{2, 12}, []int64{100, 10}))...)
	data := testPBFData(table, ways)
	var nodes []byte
	for _, id := range []int64{10, 20, 30} {
		nodes = append(nodes, testPBFPrimitiveGroup(1, testPBFNode(id, nil, nil, 480000000+id*1000, 120000000))...)
	}
	// Dense non-road nodes exceed the graph limit on their own. An unrelated
	// address must still be collected by server callers that request addresses.
	ids, lats, lons := make([]int64, 256), make([]int64, 256), make([]int64, 256)
	for i := range ids {
		ids[i], lats[i], lons[i] = 1, 1, 1
	}
	ids[0], lats[0], lons[0] = 1000, 480000000, 120000000
	nodes = append(nodes, testPBFPrimitiveGroup(2, testPBFDenseNodes(ids, lats, lons, nil))...)
	nodes = append(nodes, testPBFPrimitiveGroup(1, testPBFNode(4000, []uint64{7, 9}, []uint64{8, 10}, 480000000, 120000000))...)
	data = append(data, testPBFData(table, nodes)...)
	path := filepath.Join(t.TempDir(), "roads.osm.pbf")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRoadImportIgnoresUnrelatedNodesAndKeepsAddresses(t *testing.T) {
	path := roadImportFixture(t)
	for _, skipAddresses := range []bool{false, true} {
		router, addresses, err := BuildRouterWithAddressesOptions(path, BuildOptions{Context: t.Context(), MaxNodes: 4, SkipAddresses: skipAddresses})
		if err != nil {
			t.Fatal(err)
		}
		if router.NodeCount() != 3 || router.EdgeCount() != 2 {
			t.Fatalf("graph = %d nodes / %d edges, want 3 / 2", router.NodeCount(), router.EdgeCount())
		}
		coords, _ := router.ExportGraph()
		if _, invented := coords[90]; invented {
			t.Fatal("missing road coordinate was replaced with a zero coordinate")
		}
		if _, sink := coords[30]; !sink {
			t.Fatal("pruning lost the sink of the one-way road")
		}
		wantAddresses := 1
		if skipAddresses {
			wantAddresses = 0
		}
		if len(addresses) != wantAddresses || !skipAddresses && addresses[0].ID != 4000 {
			t.Fatalf("addresses = %+v (skip=%v)", addresses, skipAddresses)
		}
		route, err := router.RouteWithOptions(t.Context(), 10, 30, RouteOptions{Engine: EngineDijkstra})
		if err != nil || len(route.Path) != 3 || route.DistanceM <= 0 {
			t.Fatalf("route through retained road: %+v, %v", route, err)
		}
		if _, err := router.RouteWithOptions(t.Context(), 30, 10, RouteOptions{Engine: EngineDijkstra}); err == nil {
			t.Fatal("one-way direction was lost")
		}
	}
}

func TestRoadImportStillEnforcesItsNodeLimit(t *testing.T) {
	_, _, err := BuildRouterWithAddressesOptions(roadImportFixture(t), BuildOptions{Context: t.Context(), MaxNodes: 2, SkipAddresses: true})
	if err == nil || !strings.Contains(err.Error(), "exceeds 2 road nodes") {
		t.Fatalf("road-node bound was not enforced: %v", err)
	}
}

func TestRoadImportWindowCountsOnlyRetainedCoordinates(t *testing.T) {
	window := CoordWindow{MinLat: 48.0015, MaxLat: 48.0035, MinLon: 11.99, MaxLon: 12.01}
	router, addresses, err := BuildRouterWithAddressesOptions(roadImportFixture(t), BuildOptions{Context: t.Context(), MaxNodes: 2, Window: &window})
	if err != nil {
		t.Fatal(err)
	}
	if router.NodeCount() != 2 || router.EdgeCount() != 1 || len(addresses) != 0 {
		t.Fatalf("window = %d nodes / %d edges / %d addresses, want 2 / 1 / 0", router.NodeCount(), router.EdgeCount(), len(addresses))
	}
	if _, err := router.RouteWithOptions(t.Context(), 20, 30, RouteOptions{Engine: EngineDijkstra}); err != nil {
		t.Fatalf("windowed route: %v", err)
	}
}
