//go:build sqliteimport

package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// createMBTilesFixture builds a minimal, real MBTiles SQLite file. The tiles
// table's tile_row already uses TMS convention (the format MBTiles itself
// uses), matching tinySQL's own artifact_test.go fixture.
func createMBTilesFixture(t *testing.T, path, format string) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open fixture db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`
		CREATE TABLE metadata (name TEXT, value TEXT);
		CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
		INSERT INTO metadata VALUES ('format', ?), ('name', 'osmmini fixture'), ('minzoom', '0'), ('maxzoom', '2');
	`, format); err != nil {
		t.Fatalf("create fixture schema: %v", err)
	}
	// z=1, TMS x=0,y=0 (== XYZ x=0,y=1) gets a distinctive payload used by
	// the XYZ->TMS flip assertion below.
	if _, err := db.Exec(`INSERT INTO tiles VALUES (1,0,0,?)`, []byte{0xAA, 0xBB}); err != nil {
		t.Fatalf("insert fixture tile: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO tiles VALUES (1,0,1,?)`, []byte{0xCC, 0xDD}); err != nil {
		t.Fatalf("insert fixture tile: %v", err)
	}
}

func newGeodataTilesTestServer(t *testing.T) *server {
	t.Helper()
	return &server{customTilesDir: filepath.Join(t.TempDir(), "geodata-tiles")}
}

func TestGeodataMBTilesImportAndServeRaster(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	fixture := filepath.Join(t.TempDir(), "source.mbtiles")
	createMBTilesFixture(t, fixture, "png")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	importRec := httptest.NewRecorder()
	s.handleGeodataMBTiles(importRec, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(raw)))
	if importRec.Code != http.StatusOK {
		t.Fatalf("import status = %d: %s", importRec.Code, importRec.Body.String())
	}
	var info customTilesInfo
	if err := json.Unmarshal(importRec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Format != "png" || info.IsVector || info.MinZoom != 0 || info.MaxZoom != 2 {
		t.Fatalf("info = %+v", info)
	}

	statusRec := httptest.NewRecorder()
	s.handleGeodataMBTiles(statusRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/mbtiles", nil))
	if statusRec.Code != http.StatusOK || !bytes.Contains(statusRec.Body.Bytes(), []byte(`"loaded":true`)) {
		t.Fatalf("status status=%d body=%s", statusRec.Code, statusRec.Body.String())
	}

	// TMS (z=1,x=0,y=0) == XYZ (z=1,x=0,y=1): the row must be flipped.
	tileRec := httptest.NewRecorder()
	s.handleGeodataTile(tileRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/1/0/1.png", nil))
	if tileRec.Code != http.StatusOK {
		t.Fatalf("tile status = %d: %s", tileRec.Code, tileRec.Body.String())
	}
	if got := tileRec.Body.Bytes(); !bytes.Equal(got, []byte{0xAA, 0xBB}) {
		t.Fatalf("tile data = %x, want aabb (XYZ y=1 should map to TMS y=0)", got)
	}
	if ct := tileRec.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("content-type = %q, want image/png", ct)
	}

	// XYZ y=0 -> TMS y=1 -> the other fixture tile.
	otherRec := httptest.NewRecorder()
	s.handleGeodataTile(otherRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/1/0/0.png", nil))
	if got := otherRec.Body.Bytes(); !bytes.Equal(got, []byte{0xCC, 0xDD}) {
		t.Fatalf("tile data = %x, want ccdd", got)
	}

	// A tile outside the fixture's data returns 204, not an error.
	emptyRec := httptest.NewRecorder()
	s.handleGeodataTile(emptyRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/1/1/1.png", nil))
	if emptyRec.Code != http.StatusNoContent {
		t.Fatalf("empty tile status = %d, want 204", emptyRec.Code)
	}

	if preset := s.geodataCustomTilePreset(); preset == nil || preset.MapType != "raster-direct" {
		t.Fatalf("geodataCustomTilePreset() = %+v, want a raster-direct preset", preset)
	}

	// DELETE clears the slot; subsequent tile requests 404.
	deleteRec := httptest.NewRecorder()
	s.handleGeodataMBTiles(deleteRec, httptest.NewRequest(http.MethodDelete, "/api/v1/geodata/mbtiles", nil))
	if deleteRec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d: %s", deleteRec.Code, deleteRec.Body.String())
	}
	goneRec := httptest.NewRecorder()
	s.handleGeodataTile(goneRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/1/0/1.png", nil))
	if goneRec.Code != http.StatusNotFound {
		t.Fatalf("tile after delete = %d, want 404", goneRec.Code)
	}
	if preset := s.geodataCustomTilePreset(); preset != nil {
		t.Fatalf("geodataCustomTilePreset() after delete = %+v, want nil", preset)
	}
}

func TestGeodataMBTilesVectorFormatNotOfferedAsRasterPreset(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	fixture := filepath.Join(t.TempDir(), "source.mbtiles")
	createMBTilesFixture(t, fixture, "pbf")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	importRec := httptest.NewRecorder()
	s.handleGeodataMBTiles(importRec, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(raw)))
	if importRec.Code != http.StatusOK {
		t.Fatalf("import status = %d: %s", importRec.Code, importRec.Body.String())
	}
	var info customTilesInfo
	if err := json.Unmarshal(importRec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if !info.IsVector {
		t.Fatalf("info.IsVector = false for format=pbf, want true")
	}
	// Vector MBTiles are importable and servable (Scope V1) but deliberately
	// not offered as a one-click raster source -- no automatic MapLibre
	// style generation (see the approved plan's "Bewusst nicht im Umfang").
	if preset := s.geodataCustomTilePreset(); preset != nil {
		t.Fatalf("geodataCustomTilePreset() for a vector MBTiles = %+v, want nil", preset)
	}

	tileRec := httptest.NewRecorder()
	s.handleGeodataTile(tileRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/1/0/1.pbf", nil))
	if tileRec.Code != http.StatusOK {
		t.Fatalf("tile status = %d: %s", tileRec.Code, tileRec.Body.String())
	}
	if ct := tileRec.Header().Get("Content-Type"); ct != "application/x-protobuf" {
		t.Fatalf("content-type = %q, want application/x-protobuf", ct)
	}
}

func TestGeodataMBTilesImportRequiresAdminTokenWhenConfigured(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	s.adminToken = "secret-token"
	fixture := filepath.Join(t.TempDir(), "source.mbtiles")
	createMBTilesFixture(t, fixture, "png")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	unauthorized := httptest.NewRecorder()
	s.handleGeodataMBTiles(unauthorized, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(raw)))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("import without a token = %d, want 401", unauthorized.Code)
	}

	authorized := httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(raw))
	authorized.Header.Set("Authorization", "Bearer secret-token")
	authorizedRec := httptest.NewRecorder()
	s.handleGeodataMBTiles(authorizedRec, authorized)
	if authorizedRec.Code != http.StatusOK {
		t.Fatalf("import with a valid token = %d: %s", authorizedRec.Code, authorizedRec.Body.String())
	}

	// GET (status) is not gated -- it reveals no sensitive data, only
	// whether a source is loaded, mirroring handleGeodataLayers.
	statusRec := httptest.NewRecorder()
	s.handleGeodataMBTiles(statusRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/mbtiles", nil))
	if statusRec.Code != http.StatusOK {
		t.Fatalf("unauthenticated status = %d, want 200", statusRec.Code)
	}
}

func TestGeodataMBTilesReimportReplacesSlot(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	first := filepath.Join(t.TempDir(), "first.mbtiles")
	createMBTilesFixture(t, first, "png")
	firstRaw, err := os.ReadFile(first)
	if err != nil {
		t.Fatal(err)
	}
	rec1 := httptest.NewRecorder()
	s.handleGeodataMBTiles(rec1, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(firstRaw)))
	if rec1.Code != http.StatusOK {
		t.Fatalf("first import status = %d: %s", rec1.Code, rec1.Body.String())
	}

	second := filepath.Join(t.TempDir(), "second.mbtiles")
	createMBTilesFixture(t, second, "jpg")
	secondRaw, err := os.ReadFile(second)
	if err != nil {
		t.Fatal(err)
	}
	rec2 := httptest.NewRecorder()
	s.handleGeodataMBTiles(rec2, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(secondRaw)))
	if rec2.Code != http.StatusOK {
		t.Fatalf("second import status = %d: %s", rec2.Code, rec2.Body.String())
	}
	var info customTilesInfo
	if err := json.Unmarshal(rec2.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Format != "jpg" {
		t.Fatalf("after re-import format = %q, want jpg (last import wins)", info.Format)
	}

	tileRec := httptest.NewRecorder()
	s.handleGeodataTile(tileRec, httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/1/0/1.jpg", nil))
	if tileRec.Code != http.StatusOK {
		t.Fatalf("tile after re-import status = %d: %s", tileRec.Code, tileRec.Body.String())
	}
}

func TestGeodataMBTilesReloadsOnRestart(t *testing.T) {
	s := newGeodataTilesTestServer(t)
	fixture := filepath.Join(t.TempDir(), "source.mbtiles")
	createMBTilesFixture(t, fixture, "png")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	s.handleGeodataMBTiles(rec, httptest.NewRequest(http.MethodPost, "/api/v1/geodata/mbtiles", bytes.NewReader(raw)))
	if rec.Code != http.StatusOK {
		t.Fatalf("import status = %d: %s", rec.Code, rec.Body.String())
	}

	restarted := &server{customTilesDir: s.customTilesDir}
	restarted.loadCustomTiles()
	if restarted.customTiles == nil {
		t.Fatal("loadCustomTiles did not pick up the previously imported artifact")
	}
	if restarted.customTilesInfo.Format != "png" {
		t.Fatalf("restarted info = %+v", restarted.customTilesInfo)
	}
}
