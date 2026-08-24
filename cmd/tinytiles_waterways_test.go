package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestBuildTinyTilesWaterwaySidecar(t *testing.T) {
	pbfPath := filepath.Join(t.TempDir(), "waterways.osm.pbf")
	if err := os.WriteFile(pbfPath, tinyTilesWaterwayPBF(), 0o600); err != nil {
		t.Fatalf("write PBF fixture: %v", err)
	}
	sidecarPath := filepath.Join(t.TempDir(), "basemap.waterways.json")
	count, err := buildTinyTilesWaterwaySidecar(pbfPath, sidecarPath)
	if err != nil {
		t.Fatalf("build waterway sidecar: %v", err)
	}
	if count != 2 {
		t.Fatalf("waterway count = %d, want 2 supported open waterways", count)
	}
	index, err := loadTinyTilesWaterwaySidecar(sidecarPath)
	if err != nil {
		t.Fatalf("load waterway sidecar: %v", err)
	}
	if index.len() != 2 {
		t.Fatalf("loaded waterway count = %d, want 2", index.len())
	}
	classes := map[string]int{}
	for _, feature := range index.features {
		classes[feature.Class]++
		if len(feature.Coordinates) != 2 {
			t.Fatalf("feature %d has %d coordinates, want 2", feature.ID, len(feature.Coordinates))
		}
		if feature.ID == 10 {
			if feature.Name != "Vils" {
				t.Fatalf("river name = %q, want Vils", feature.Name)
			}
			want := [][2]float64{{11, 48}, {11.01, 48.01}}
			if !tinyTilesWaterwayCoordinatesEqual(feature.Coordinates, want) {
				t.Fatalf("river coordinates = %#v, want %#v", feature.Coordinates, want)
			}
		}
	}
	if classes["river"] != 1 || classes["stream"] != 1 {
		t.Fatalf("waterway classes = %#v, want one river and one stream", classes)
	}
}

func TestTinyTilesWaterwaysAreViewportBoundAndClipped(t *testing.T) {
	river := tinyTilesWaterway{
		ID: 1, Class: "river", MinZoom: 7,
		Coordinates: [][2]float64{{10, 48}, {12, 48}},
	}
	stream := tinyTilesWaterway{
		ID: 2, Class: "stream", MinZoom: 11,
		Coordinates: [][2]float64{{10.7, 47.8}, {10.8, 48.2}},
	}
	if !river.normalize() || !stream.normalize() {
		t.Fatal("test waterways should normalize")
	}
	s := &server{tinyTilesWaterways: newTinyTilesWaterwayIndex([]tinyTilesWaterway{river, stream})}

	request := httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/waterways?bbox=10.5,47.5,11.5,48.5&zoom=8", nil)
	response := httptest.NewRecorder()
	s.handleTinyTilesWaterways(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("waterways response = %d: %s", response.Code, response.Body.String())
	}
	var payload tinyTilesWaterwayGeoJSON
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode waterways response: %v", err)
	}
	if payload.Type != "FeatureCollection" || len(payload.Features) != 1 {
		t.Fatalf("zoom 8 response = %#v, want one major-waterway feature", payload)
	}
	coords := payload.Features[0].Geometry.Coordinates
	if got, want := coords, [][2]float64{{10.5, 48}, {11.5, 48}}; !tinyTilesWaterwayCoordinatesEqual(got, want) {
		t.Fatalf("clipped river = %#v, want %#v", got, want)
	}

	response = httptest.NewRecorder()
	s.handleTinyTilesWaterways(response, httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/waterways?bbox=10.5,47.5,11.5,48.5&zoom=11", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("zoom 11 response = %d: %s", response.Code, response.Body.String())
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode zoom 11 waterways response: %v", err)
	}
	if len(payload.Features) != 2 {
		t.Fatalf("zoom 11 features = %d, want river and stream", len(payload.Features))
	}

	bad := httptest.NewRecorder()
	s.handleTinyTilesWaterways(bad, httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/waterways?bbox=invalid&zoom=11", nil))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("invalid bbox status = %d, want %d", bad.Code, http.StatusBadRequest)
	}
}

func TestTinyTilesWaterwaysPrioritizeRiversAndBoundLargeRequests(t *testing.T) {
	features := make([]tinyTilesWaterway, 0, 701)
	for id := int64(1); id <= 700; id++ {
		stream := tinyTilesWaterway{
			ID: id, Class: "stream", MinZoom: 11,
			Coordinates: [][2]float64{{10.6, 47.9}, {10.7, 48.1}},
		}
		if !stream.normalize() {
			t.Fatal("test stream should normalize")
		}
		features = append(features, stream)
	}
	river := tinyTilesWaterway{
		ID: 9_999, Class: "river", MinZoom: 7,
		Coordinates: [][2]float64{{10.1, 48}, {11.9, 48}},
	}
	if !river.normalize() {
		t.Fatal("test river should normalize")
	}
	features = append(features, river)
	s := &server{tinyTilesWaterways: newTinyTilesWaterwayIndex(features)}

	response := httptest.NewRecorder()
	s.handleTinyTilesWaterways(response, httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/waterways?bbox=10,47.5,12,48.5&zoom=11", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("waterways response = %d: %s", response.Code, response.Body.String())
	}
	var payload tinyTilesWaterwayGeoJSON
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode waterways response: %v", err)
	}
	if len(payload.Features) != tinyTilesWaterwayResultLimit(11) || !payload.Truncated {
		t.Fatalf("limited response = %d features, truncated=%t", len(payload.Features), payload.Truncated)
	}
	if got := payload.Features[0].Properties.Class; got != "river" {
		t.Fatalf("first limited feature = %q, want river", got)
	}

	tooLarge := httptest.NewRecorder()
	s.handleTinyTilesWaterways(tooLarge, httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/waterways?bbox=-180,-90,180,90&zoom=11", nil))
	if tooLarge.Code != http.StatusBadRequest {
		t.Fatalf("world bbox status = %d, want %d", tooLarge.Code, http.StatusBadRequest)
	}
}

func TestOfflineWaterwaysUIAndHiddenUseCaseSectionAreShipped(t *testing.T) {
	index, err := embedded.ReadFile("web/index.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range [][]byte{
		[]byte(`class="settings-section use-case-section" hidden`),
		[]byte(`Flüsse, Bäche und Kanäle werden als lokale Vektorebene ergänzt.`),
		[]byte(`for="profile"`), []byte(`for="engine"`), []byte(`for="objective"`),
	} {
		if !bytes.Contains(index, marker) {
			t.Fatalf("settings UI misses %s", marker)
		}
	}
	app, err := embedded.ReadFile("web/app.js")
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range [][]byte{
		[]byte(`const OFFLINE_WATERWAYS_SOURCE_ID = 'offline-waterways'`),
		[]byte(`/api/v1/tinytiles/waterways?bbox=`),
		[]byte(`setOfflineWaterwaysVisible(isTinyTilesSettings(tiles))`),
		[]byte(`offlineWaterwaysRequest?.abort();`),
		[]byte(`['Gewässerobjekte', number.format(waterways)]`),
		[]byte(`if (!document.querySelector('.use-case-section[hidden]')) loadUseCases();`),
	} {
		if !bytes.Contains(app, marker) {
			t.Fatalf("web app misses %s", marker)
		}
	}
}

func tinyTilesWaterwayCoordinatesEqual(got, want [][2]float64) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}

// tinyTilesWaterwayPBF makes a minimal uncompressed OSM PBF with a river, a
// stream, and a riverbank polygon. The latter proves that the companion layer
// only emits linear waterways; closed water surfaces remain tinyTiles' own
// responsibility.
func tinyTilesWaterwayPBF() []byte {
	strings := []string{"", "waterway", "river", "name", "Vils", "stream", "riverbank"}
	group := make([]byte, 0)
	group = append(group, tinyTilesWaterwayPrimitiveGroup(1, tinyTilesWaterwayNode(1, 480000000, 110000000))...)
	group = append(group, tinyTilesWaterwayPrimitiveGroup(1, tinyTilesWaterwayNode(2, 480100000, 110100000))...)
	group = append(group, tinyTilesWaterwayPrimitiveGroup(1, tinyTilesWaterwayNode(3, 480200000, 110200000))...)
	group = append(group, tinyTilesWaterwayPrimitiveGroup(3, tinyTilesWaterwayWay(10, []uint64{1, 3}, []uint64{2, 4}, []int64{1, 1}))...)
	group = append(group, tinyTilesWaterwayPrimitiveGroup(3, tinyTilesWaterwayWay(11, []uint64{1}, []uint64{5}, []int64{2, 1}))...)
	group = append(group, tinyTilesWaterwayPrimitiveGroup(3, tinyTilesWaterwayWay(12, []uint64{1}, []uint64{6}, []int64{1, 1, 1, -2}))...)
	// A way with a missing middle node must not be bridged into a false river.
	group = append(group, tinyTilesWaterwayPrimitiveGroup(3, tinyTilesWaterwayWay(13, []uint64{1}, []uint64{2}, []int64{1, 996, -995}))...)

	block := tinyTilesWaterwayBytesField(1, tinyTilesWaterwayStringTable(strings))
	block = append(block, tinyTilesWaterwayBytesField(2, group)...)
	blob := tinyTilesWaterwayBytesField(1, block)
	header := tinyTilesWaterwayBytesField(1, []byte("OSMData"))
	header = append(header, tinyTilesWaterwayVarintField(3, uint64(len(blob)))...)
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(header)))
	return append(append(length[:], header...), blob...)
}

func tinyTilesWaterwayStringTable(strings []string) []byte {
	var out []byte
	for _, value := range strings {
		out = append(out, tinyTilesWaterwayBytesField(1, []byte(value))...)
	}
	return out
}

func tinyTilesWaterwayPrimitiveGroup(field int, entity []byte) []byte {
	return tinyTilesWaterwayBytesField(field, entity)
}

func tinyTilesWaterwayNode(id, lat, lon int64) []byte {
	out := tinyTilesWaterwayVarintField(1, tinyTilesWaterwayZigZag(id))
	out = append(out, tinyTilesWaterwayVarintField(8, tinyTilesWaterwayZigZag(lat))...)
	out = append(out, tinyTilesWaterwayVarintField(9, tinyTilesWaterwayZigZag(lon))...)
	return out
}

func tinyTilesWaterwayWay(id int64, keys, values []uint64, refs []int64) []byte {
	out := tinyTilesWaterwayVarintField(1, uint64(id))
	out = append(out, tinyTilesWaterwayPackedUvarints(2, keys)...)
	out = append(out, tinyTilesWaterwayPackedUvarints(3, values)...)
	out = append(out, tinyTilesWaterwayPackedSint64s(8, refs)...)
	return out
}

func tinyTilesWaterwayPackedUvarints(field int, values []uint64) []byte {
	var packed []byte
	for _, value := range values {
		packed = tinyTilesWaterwayAppendUvarint(packed, value)
	}
	return tinyTilesWaterwayBytesField(field, packed)
}

func tinyTilesWaterwayPackedSint64s(field int, values []int64) []byte {
	var packed []byte
	for _, value := range values {
		packed = tinyTilesWaterwayAppendUvarint(packed, tinyTilesWaterwayZigZag(value))
	}
	return tinyTilesWaterwayBytesField(field, packed)
}

func tinyTilesWaterwayVarintField(field int, value uint64) []byte {
	out := tinyTilesWaterwayAppendUvarint(nil, uint64(field<<3))
	return tinyTilesWaterwayAppendUvarint(out, value)
}

func tinyTilesWaterwayBytesField(field int, value []byte) []byte {
	out := tinyTilesWaterwayAppendUvarint(nil, uint64(field<<3|2))
	out = tinyTilesWaterwayAppendUvarint(out, uint64(len(value)))
	return append(out, value...)
}

func tinyTilesWaterwayAppendUvarint(dst []byte, value uint64) []byte {
	for value >= 0x80 {
		dst = append(dst, byte(value)|0x80)
		value >>= 7
	}
	return append(dst, byte(value))
}

func tinyTilesWaterwayZigZag(value int64) uint64 {
	return uint64(value<<1) ^ uint64(value>>63)
}
