//go:build sqliteimport

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// buildFixtureGeoTIFF hand-builds a minimal, real, uncompressed 8-bit
// grayscale GeoTIFF: baseline TIFF tags for golang.org/x/image/tiff to
// decode the pixels, plus ModelPixelScaleTag/ModelTiepointTag/
// GeoKeyDirectoryTag for cmd/geodata_geotiff.go's own raw-tag georeferencing
// parser. IFD entries must be in strictly ascending tag order (the decoder
// rejects an unsorted IFD) -- 256..279 (baseline) then 33550/33922/34735
// (GeoTIFF) already satisfies that.
func buildFixtureGeoTIFF(t *testing.T, epsg int, originX, originY, pixelSizeX, pixelSizeY float64, w, h int, pixels []byte) []byte {
	t.Helper()
	if len(pixels) != w*h {
		t.Fatalf("pixels length %d != %d*%d", len(pixels), w, h)
	}
	order := binary.LittleEndian

	var pixelScaleBytes, tiepointBytes, geoKeyBytes bytes.Buffer
	for _, v := range []float64{pixelSizeX, pixelSizeY, 0} {
		if err := binary.Write(&pixelScaleBytes, order, v); err != nil {
			t.Fatal(err)
		}
	}
	for _, v := range []float64{0, 0, 0, originX, originY, 0} {
		if err := binary.Write(&tiepointBytes, order, v); err != nil {
			t.Fatal(err)
		}
	}
	modelType, csKeyID := uint16(2), uint16(2048) // Geographic / GeographicTypeGeoKey
	if epsg == 3857 {
		modelType, csKeyID = 1, 3072 // Projected / ProjectedCSTypeGeoKey
	}
	geoKeys := []uint16{1, 1, 0, 2, 1024, 0, 1, modelType, csKeyID, 0, 1, uint16(epsg)}
	for _, v := range geoKeys {
		if err := binary.Write(&geoKeyBytes, order, v); err != nil {
			t.Fatal(err)
		}
	}

	const numEntries = 12
	const ifdOffset = 8
	ifdBodyLen := 2 + numEntries*12 + 4
	dataStart := uint32(ifdOffset + ifdBodyLen)

	pixelScaleOff := dataStart
	tiepointOff := pixelScaleOff + uint32(pixelScaleBytes.Len())
	geoKeyOff := tiepointOff + uint32(tiepointBytes.Len())
	pixelOff := geoKeyOff + uint32(geoKeyBytes.Len())

	type entry struct {
		tag, ftype uint16
		count      uint32
		value      uint32
	}
	entries := []entry{
		{256, 3, 1, uint32(w)},
		{257, 3, 1, uint32(h)},
		{258, 3, 1, 8},
		{259, 3, 1, 1}, // Compression: none
		{262, 3, 1, 1}, // PhotometricInterpretation: BlackIsZero
		{273, 4, 1, pixelOff},
		{277, 3, 1, 1}, // SamplesPerPixel
		{278, 3, 1, uint32(h)},
		{279, 4, 1, uint32(len(pixels))},
		{33550, 12, 3, pixelScaleOff},
		{33922, 12, 6, tiepointOff},
		{34735, 3, uint32(len(geoKeys)), geoKeyOff},
	}

	var buf bytes.Buffer
	buf.WriteString("II")
	must(t, binary.Write(&buf, order, uint16(42)))
	must(t, binary.Write(&buf, order, uint32(ifdOffset)))
	must(t, binary.Write(&buf, order, uint16(numEntries)))
	for _, e := range entries {
		must(t, binary.Write(&buf, order, e.tag))
		must(t, binary.Write(&buf, order, e.ftype))
		must(t, binary.Write(&buf, order, e.count))
		must(t, binary.Write(&buf, order, e.value))
	}
	must(t, binary.Write(&buf, order, uint32(0))) // next IFD offset: none
	buf.Write(pixelScaleBytes.Bytes())
	buf.Write(tiepointBytes.Bytes())
	buf.Write(geoKeyBytes.Bytes())
	buf.Write(pixels)
	return buf.Bytes()
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// landauInDerIsar is a real point in this project's usual coverage area
// (see the A1/A2 browser verification), used so a fixture raster sits
// somewhere plausible rather than at an arbitrary coordinate.
const landauLon, landauLat = 12.706, 48.646

func TestParseGeoTIFFGeoreferenceWGS84(t *testing.T) {
	data := buildFixtureGeoTIFF(t, 4326, landauLon, landauLat, 0.001, 0.001, 4, 4, bytes.Repeat([]byte{200}, 16))
	geo, err := parseGeoTIFFGeoreference(data)
	if err != nil {
		t.Fatalf("parseGeoTIFFGeoreference: %v", err)
	}
	if geo.EPSG != 4326 || geo.OriginX != landauLon || geo.OriginY != landauLat || geo.PixelSizeX != 0.001 || geo.PixelSizeY != 0.001 {
		t.Fatalf("geo = %+v", geo)
	}
}

func TestParseGeoTIFFGeoreferenceWebMercator(t *testing.T) {
	mercX, mercY := lonLatToWebMercator(landauLon, landauLat)
	data := buildFixtureGeoTIFF(t, 3857, mercX, mercY, 10, 10, 4, 4, bytes.Repeat([]byte{100}, 16))
	geo, err := parseGeoTIFFGeoreference(data)
	if err != nil {
		t.Fatalf("parseGeoTIFFGeoreference: %v", err)
	}
	if geo.EPSG != 3857 || geo.OriginX != mercX || geo.OriginY != mercY {
		t.Fatalf("geo = %+v", geo)
	}
}

func TestParseGeoTIFFGeoreferenceRejectsUnsupportedCRS(t *testing.T) {
	// EPSG:25832 (UTM zone 32N) is a real, common projected CRS in Germany,
	// but out of this feature's deliberately narrow scope.
	data := buildFixtureGeoTIFF(t, 25832, 500000, 5400000, 10, 10, 2, 2, []byte{1, 2, 3, 4})
	_, err := parseGeoTIFFGeoreference(data)
	if err == nil {
		t.Fatal("expected an error for an unsupported CRS")
	}
}

func TestParseGeoTIFFGeoreferenceRejectsNonTIFF(t *testing.T) {
	if _, err := parseGeoTIFFGeoreference([]byte("not a tiff file at all")); err == nil {
		t.Fatal("expected an error for non-TIFF input")
	}
}

func TestGeodataGeoTIFFImportAndServe(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	// A flat mid-gray 4x4 raster centered on Landau an der Isar, ~0.004deg
	// (roughly 300-400m) across -- small enough to keep the generated
	// pyramid tiny even at a modest max_zoom.
	data := buildFixtureGeoTIFF(t, 4326, landauLon-0.002, landauLat+0.002, 0.001, 0.001, 4, 4, bytes.Repeat([]byte{128}, 16))

	req := httptest.NewRequest(http.MethodPost, "/api/v1/geodata/geotiff?max_zoom=10", bytes.NewReader(data))
	rec := httptest.NewRecorder()
	s.handleGeodataGeoTIFF(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("import status = %d: %s", rec.Code, rec.Body.String())
	}
	var info customTilesInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Format != "png" || info.IsVector {
		t.Fatalf("info = %+v", info)
	}

	preset := s.geodataCustomTilePreset()
	if preset == nil || preset.MapType != "raster-direct" {
		t.Fatalf("geodataCustomTilePreset() = %+v", preset)
	}

	// Web Mercator tile (z=10) covering Landau an der Isar must contain the
	// imported raster's data.
	mercX, mercY := lonLatToWebMercator(landauLon, landauLat)
	n := 1 << 10
	tileM := (2 * webMercatorOriginShift) / float64(n)
	tx := int((mercX + webMercatorOriginShift) / tileM)
	tyTMS := int((mercY + webMercatorOriginShift) / tileM)
	xyzY := n - 1 - tyTMS

	tileRec := httptest.NewRecorder()
	tileReq := httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/10/"+strconv.Itoa(tx)+"/"+strconv.Itoa(xyzY)+".png", nil)
	s.handleGeodataTile(tileRec, tileReq)
	if tileRec.Code != http.StatusOK {
		t.Fatalf("tile status = %d: %s", tileRec.Code, tileRec.Body.String())
	}
	if ct := tileRec.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("content-type = %q", ct)
	}
	if tileRec.Body.Len() == 0 {
		t.Fatal("tile response is empty")
	}
}

func TestGeodataGeoTIFFRejectsBadMaxZoom(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	data := buildFixtureGeoTIFF(t, 4326, landauLon, landauLat, 0.001, 0.001, 2, 2, []byte{1, 2, 3, 4})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/geodata/geotiff?max_zoom=99", bytes.NewReader(data))
	rec := httptest.NewRecorder()
	s.handleGeodataGeoTIFF(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestGeodataGeoTIFFRejectsUnsupportedCRS(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	data := buildFixtureGeoTIFF(t, 25832, 500000, 5400000, 10, 10, 2, 2, []byte{1, 2, 3, 4})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/geodata/geotiff", bytes.NewReader(data))
	rec := httptest.NewRecorder()
	s.handleGeodataGeoTIFF(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400: %s", rec.Code, rec.Body.String())
	}
}

func TestGeodataGeoTIFFSharesSlotWithMBTiles(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	mbtiles := filepath.Join(t.TempDir(), "source.mbtiles")
	createMBTilesFixture(t, mbtiles, "jpg")
	raw, err := os.ReadFile(mbtiles)
	if err != nil {
		t.Fatal(err)
	}
	rec1 := httptest.NewRecorder()
	s.handleGeodataMBTiles(rec1, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(raw)))
	if rec1.Code != http.StatusOK {
		t.Fatalf("mbtiles import status = %d: %s", rec1.Code, rec1.Body.String())
	}

	// max_zoom must be high enough that the tile-sampling grid (tile size /
	// 256) is finer than the raster's own extent, or nearest-neighbor point
	// sampling can miss a small raster between sample points -- see
	// buildGeoTIFFTileSource's doc comment. This raster is only ~220m
	// across, so a low max_zoom (coarser than ~1km/tile) isn't representative
	// of a real import and would spuriously fail here.
	data := buildFixtureGeoTIFF(t, 4326, landauLon, landauLat, 0.001, 0.001, 2, 2, []byte{1, 2, 3, 4})
	rec2 := httptest.NewRecorder()
	s.handleGeodataGeoTIFF(rec2, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/geotiff?max_zoom=18", bytes.NewReader(data)))
	if rec2.Code != http.StatusOK {
		t.Fatalf("geotiff import status = %d: %s", rec2.Code, rec2.Body.String())
	}
	var info customTilesInfo
	if err := json.Unmarshal(rec2.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	// The GeoTIFF import replaced the MBTiles-imported slot -- there is only
	// one, per the approved plan's scope decision.
	if info.Format != "png" {
		t.Fatalf("after geotiff import, format = %q, want png (mbtiles jpg should have been replaced)", info.Format)
	}
}
