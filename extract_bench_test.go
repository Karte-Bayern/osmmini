package osmmini

import "testing"

func BenchmarkDenseNodes(b *testing.B) {
	const count = 8000
	ids, lats, lons := make([]int64, count), make([]int64, count), make([]int64, count)
	keysVals := make([]uint64, 0, count*3)
	for i := range ids {
		ids[i], lats[i], lons[i] = 1, 1, 1
		keysVals = append(keysVals, 1, 2, 0)
	}
	lats[0], lons[0] = 480000000, 110000000
	raw := testPBFDenseNodes(ids, lats, lons, keysVals)
	ctx := blockCtx{st: []string{"", "amenity", "cafe"}, granularity: 100}
	for _, tagged := range []bool{false, true} {
		name := "Coordinates"
		cb := Callbacks{Node: func(int64, float64, float64) error { return nil }}
		if tagged {
			name = "Tagged"
			cb.TaggedNode = func(Node) error { return nil }
		}
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(raw)))
			for b.Loop() {
				if err := processDenseNodes(raw, ctx, Options{}, cb); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkPBFWay(b *testing.B) {
	ctx := blockCtx{st: []string{"", "highway", "residential", "name", "Teststraße", "surface", "asphalt"}, granularity: 100}
	raw := testPBFWay(1, []uint64{1, 3, 5}, []uint64{2, 4, 6}, []int64{10000000, 1, 1, 1, 1, 1, 1, 1, 1, 1})
	opts := Options{EmitWayNodeIDs: true}
	cb := Callbacks{HighwayWay: func(Way) error { return nil }}
	b.ReportAllocs()
	for b.Loop() {
		if err := processWay(raw, ctx, true, false, opts, cb); err != nil {
			b.Fatal(err)
		}
	}
}
