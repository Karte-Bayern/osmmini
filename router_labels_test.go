package osmmini

import (
	"fmt"
	"reflect"
	"testing"
)

func TestStreetLabelsUsesOnlyVisibleSampleNodes(t *testing.T) {
	r := &Router{
		g: Graph{coords: map[int64]Coord{
			1: {Lat: 48.10, Lon: 11.10},
			2: {Lat: 49.10, Lon: 12.10},
		}},
		streets: map[string]streetEntry{
			"main":  {Display: "Hauptstraße", NodeIDs: []int64{1}},
			"other": {Display: "Fernstraße", NodeIDs: []int64{2}},
		},
	}
	labels := r.StreetLabels(CoordWindow{MinLat: 48, MaxLat: 48.5, MinLon: 11, MaxLon: 11.5}, 10)
	if len(labels) != 1 || labels[0].Name != "Hauptstraße" || labels[0].Coord.Lat != 48.10 {
		t.Fatalf("StreetLabels() = %#v", labels)
	}
	if got := r.StreetLabels(CoordWindow{}, 10); got != nil {
		t.Fatalf("StreetLabels invalid window = %#v, want nil", got)
	}
}

func TestStreetLabelsCoverViewportDespiteDenseCenter(t *testing.T) {
	r := &Router{g: Graph{coords: map[int64]Coord{}}, streets: map[string]streetEntry{}}
	for i := 1; i <= 100; i++ {
		name := fmt.Sprintf("Center %03d", i)
		r.g.coords[int64(i)] = Coord{Lat: 48.5 + float64(i)*0.00001, Lon: 11.5}
		r.streets[name] = streetEntry{Display: name, NodeIDs: []int64{int64(i)}}
	}
	for i, coord := range []Coord{{48.05, 11.05}, {48.05, 11.95}, {48.95, 11.05}, {48.95, 11.95}} {
		id := int64(101 + i)
		name := fmt.Sprintf("Edge %d", i)
		r.g.coords[id] = coord
		r.streets[name] = streetEntry{Display: name, NodeIDs: []int64{id}}
	}
	window := CoordWindow{MinLat: 48, MaxLat: 49, MinLon: 11, MaxLon: 12}
	scan := r.StreetLabels(window, 32)
	r.streetLabelCells = buildStreetLabelCells(r.streets, r.g.coords)
	indexed := r.StreetLabels(window, 32)
	if !reflect.DeepEqual(scan, indexed) {
		t.Fatal("indexed and fallback label selection differ")
	}
	if len(indexed) != 32 {
		t.Fatalf("got %d labels, want 32", len(indexed))
	}
	names := map[string]bool{}
	for _, label := range indexed {
		names[label.Name] = true
	}
	for i := 0; i < 4; i++ {
		if !names[fmt.Sprintf("Edge %d", i)] {
			t.Fatalf("missing viewport corner %d", i)
		}
	}
}
