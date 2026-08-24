package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tinytiles "github.com/Karte-Bayern/tinyTiles/v2"
	tiles "github.com/SimonWaldherr/tinySQL/tiles"
)

func TestTinyTilesBuildStatusIncludesPublicProgress(t *testing.T) {
	s := &server{}
	recorder := httptest.NewRecorder()
	s.handleTinyTilesBuild(recorder, httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/build", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status endpoint = %d, want %d", recorder.Code, http.StatusOK)
	}

	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if got, want := payload["state"], "idle"; got != want {
		t.Fatalf("state = %#v, want %q", got, want)
	}
	if got, want := payload["phase"], "idle"; got != want {
		t.Fatalf("phase = %#v, want %q", got, want)
	}
	if got, want := payload["progress"], float64(0); got != want {
		t.Fatalf("progress = %#v, want %#v", got, want)
	}
}

func TestTinyTilesPublicBuildProgress(t *testing.T) {
	tests := []struct {
		name         string
		input        tinytiles.PBFBuildProgress
		wantPhase    string
		wantProgress int
	}{
		{
			name:         "generation starts",
			input:        tinytiles.PBFBuildProgress{Phase: "generate"},
			wantPhase:    "generating",
			wantProgress: 5,
		},
		{
			name:         "generation complete",
			input:        tinytiles.PBFBuildProgress{Phase: "generated"},
			wantPhase:    "importing",
			wantProgress: 55,
		},
		{
			name: "import follows completed rows",
			input: tinytiles.PBFBuildProgress{
				Phase:  "import",
				Import: &tiles.Progress{RowsRead: 50, RowsWritten: 50, TotalRows: 100},
			},
			wantPhase:    "importing",
			wantProgress: 78,
		},
		{
			name: "import uses the furthest read or write count",
			input: tinytiles.PBFBuildProgress{
				Phase:  "import",
				Import: &tiles.Progress{RowsRead: 100, RowsWritten: 90, TotalRows: 100},
			},
			wantPhase:    "importing",
			wantProgress: 95,
		},
		{
			name:         "published is finalizing",
			input:        tinytiles.PBFBuildProgress{Phase: "published"},
			wantPhase:    "finalizing",
			wantProgress: 97,
		},
		{
			name:         "unknown phase is public generic processing",
			input:        tinytiles.PBFBuildProgress{Phase: "future-internal-phase"},
			wantPhase:    "processing",
			wantProgress: 0,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			phase, progress, message := tinyTilesPublicBuildProgress(test.input)
			if phase != test.wantPhase || progress != test.wantProgress {
				t.Fatalf("progress = (%q, %d), want (%q, %d)", phase, progress, test.wantPhase, test.wantProgress)
			}
			if message == "" {
				t.Fatal("public progress message is empty")
			}
		})
	}
}

func TestTinyTilesBuildProgressDoesNotMoveBackward(t *testing.T) {
	s := &server{tinyTilesBuild: tinyTilesBuildStatus{State: "building", Phase: "importing", Progress: 80}}
	s.updateTinyTilesBuildProgress("processing", 20, "Offline-Karte wird verarbeitet…")
	if got := s.tinyTilesBuild.Progress; got != 80 {
		t.Fatalf("progress moved backwards to %d, want 80", got)
	}
}

func TestTinyTilesBuildEstimateIsPublicAndOnlyRecordedWhileBuilding(t *testing.T) {
	estimate := &tiles.ResourceEstimate{TileCount: 321, EstimatedDisk: 654 << 20}
	s := &server{tinyTilesBuild: tinyTilesBuildStatus{State: "building"}}
	s.updateTinyTilesBuildEstimate(estimate)
	if got := s.tinyTilesBuild.EstimatedTileCount; got != estimate.TileCount {
		t.Fatalf("estimated tile count = %d, want %d", got, estimate.TileCount)
	}
	if got := s.tinyTilesBuild.EstimatedDiskBytes; got != estimate.EstimatedDisk {
		t.Fatalf("estimated disk bytes = %d, want %d", got, estimate.EstimatedDisk)
	}

	s.tinyTilesBuild.State = "ready"
	s.updateTinyTilesBuildEstimate(&tiles.ResourceEstimate{TileCount: 1, EstimatedDisk: 1})
	if got := s.tinyTilesBuild.EstimatedTileCount; got != estimate.TileCount {
		t.Fatalf("estimate changed after completion to %d", got)
	}
}

// TestServeTinyTilesUsesV23HTTPOptimizations exercises the app's prefix
// rewriting. tinyTiles v2.3 publishes cache validators; they must survive the
// /tinytiles mount in osmmini. The origin is resolved from each request, so
// this test intentionally covers the dynamic (uncompressed) TileJSON path.
func TestServeTinyTilesUsesV23HTTPOptimizations(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	artifact := filepath.Join(dir, "basemap.ttiles")
	if _, err := tiles.ImportTiles(ctx, tinyTilesTestSource{}, artifact, &tiles.ImportOptions{
		BatchSize:      1,
		MaxMemoryBytes: 8 << 20,
		MinFreeBytes:   0,
	}); err != nil {
		t.Fatalf("create tinyTiles test artifact: %v", err)
	}

	s := &server{tinyTilesDir: dir}
	if err := s.installTinyTiles(artifact); err != nil {
		t.Fatalf("install tinyTiles test artifact: %v", err)
	}
	t.Cleanup(s.closeTinyTiles)

	request := httptest.NewRequest(http.MethodGet, "/tinytiles/tilejson.json", nil)
	response := httptest.NewRecorder()
	s.serveTinyTiles(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("TileJSON status = %d: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Cache-Control"); !strings.Contains(got, "max-age=300") {
		t.Fatalf("TileJSON Cache-Control = %q, want a v2.3 cache policy", got)
	}
	etag := response.Header().Get("ETag")
	if etag == "" {
		t.Fatal("TileJSON misses v2.3 ETag")
	}

	var tileJSON struct {
		Tiles []string `json:"tiles"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &tileJSON); err != nil {
		t.Fatalf("decode TileJSON: %v", err)
	}
	if len(tileJSON.Tiles) != 1 || !strings.Contains(tileJSON.Tiles[0], "/tinytiles/tiles/{z}/{x}/{y}.mvt?tinytiles_rev=") {
		t.Fatalf("TileJSON tiles = %#v, want the mounted XYZ URL", tileJSON.Tiles)
	}

	conditional := httptest.NewRequest(http.MethodGet, "/tinytiles/tilejson.json", nil)
	conditional.Header.Set("If-None-Match", etag)
	conditionalResponse := httptest.NewRecorder()
	s.serveTinyTiles(conditionalResponse, conditional)
	if conditionalResponse.Code != http.StatusNotModified {
		t.Fatalf("conditional TileJSON status = %d, want %d", conditionalResponse.Code, http.StatusNotModified)
	}
}

func TestInstallTinyTilesActivatesWaterwaySidecar(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	artifact := filepath.Join(dir, "basemap.ttiles")
	if _, err := tiles.ImportTiles(ctx, tinyTilesTestSource{}, artifact, &tiles.ImportOptions{
		BatchSize:      1,
		MaxMemoryBytes: 8 << 20,
		MinFreeBytes:   0,
	}); err != nil {
		t.Fatalf("create tinyTiles test artifact: %v", err)
	}
	river := tinyTilesWaterway{
		ID: 1, Class: "river", MinZoom: 7,
		Coordinates: [][2]float64{{10, 48}, {12, 48}},
	}
	if !river.normalize() {
		t.Fatal("test river should normalize")
	}
	if err := writeTinyTilesWaterwaySidecar(tinyTilesWaterwaySidecarPath(dir), tinyTilesWaterwaySidecar{
		Version:  tinyTilesWaterwaySidecarVersion,
		Features: []tinyTilesWaterway{river},
	}); err != nil {
		t.Fatalf("write waterway sidecar: %v", err)
	}
	if err := stampTinyTilesWaterwaySidecar(tinyTilesWaterwaySidecarPath(dir), artifact); err != nil {
		t.Fatalf("stamp waterway sidecar: %v", err)
	}

	s := &server{tinyTilesDir: dir}
	if err := s.installTinyTiles(artifact); err != nil {
		t.Fatalf("install tinyTiles test artifact: %v", err)
	}
	t.Cleanup(s.closeTinyTiles)

	response := httptest.NewRecorder()
	s.handleTinyTilesWaterways(response, httptest.NewRequest(http.MethodGet, "/api/v1/tinytiles/waterways?bbox=10.5,47.5,11.5,48.5&zoom=8", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("waterways status = %d: %s", response.Code, response.Body.String())
	}
	var payload tinyTilesWaterwayGeoJSON
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode waterways response: %v", err)
	}
	if len(payload.Features) != 1 || payload.Features[0].Properties.Class != "river" {
		t.Fatalf("waterway sidecar was not activated: %#v", payload.Features)
	}
}

func TestInstallTinyTilesRejectsMismatchedWaterwaySidecar(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	artifact := filepath.Join(dir, "basemap.ttiles")
	if _, err := tiles.ImportTiles(ctx, tinyTilesTestSource{}, artifact, &tiles.ImportOptions{
		BatchSize:      1,
		MaxMemoryBytes: 8 << 20,
		MinFreeBytes:   0,
	}); err != nil {
		t.Fatalf("create tinyTiles test artifact: %v", err)
	}
	river := tinyTilesWaterway{
		ID: 1, Class: "river", MinZoom: 7,
		Coordinates: [][2]float64{{10, 48}, {12, 48}},
	}
	if !river.normalize() {
		t.Fatal("test river should normalize")
	}
	if err := writeTinyTilesWaterwaySidecar(tinyTilesWaterwaySidecarPath(dir), tinyTilesWaterwaySidecar{
		Version:                tinyTilesWaterwaySidecarVersion,
		ArtifactManifestSHA256: "does-not-match",
		Features:               []tinyTilesWaterway{river},
	}); err != nil {
		t.Fatalf("write mismatched waterway sidecar: %v", err)
	}

	s := &server{tinyTilesDir: dir}
	if err := s.installTinyTiles(artifact); err != nil {
		t.Fatalf("install tinyTiles test artifact: %v", err)
	}
	t.Cleanup(s.closeTinyTiles)
	if s.tinyTilesHasWaterwaySidecar() {
		t.Fatal("mismatched waterway sidecar was activated")
	}
}

func TestBackfillTinyTilesWaterwaysMigratesExistingArtifact(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	pbfPath := filepath.Join(dir, "source.osm.pbf")
	if err := os.WriteFile(pbfPath, tinyTilesWaterwayPBF(), 0o600); err != nil {
		t.Fatalf("write PBF fixture: %v", err)
	}
	artifact := filepath.Join(dir, "basemap.ttiles")
	if _, err := tiles.ImportTiles(ctx, tinyTilesTestSource{}, artifact, &tiles.ImportOptions{
		BatchSize:      1,
		MaxMemoryBytes: 8 << 20,
		MinFreeBytes:   0,
	}); err != nil {
		t.Fatalf("create tinyTiles test artifact: %v", err)
	}

	s := &server{tinyTilesDir: dir, pbfPath: pbfPath, tinyTilesBuild: tinyTilesBuildStatus{State: "ready"}}
	if err := s.installTinyTiles(artifact); err != nil {
		t.Fatalf("install legacy tinyTiles artifact: %v", err)
	}
	t.Cleanup(s.closeTinyTiles)
	if s.tinyTilesHasWaterwaySidecar() {
		t.Fatal("legacy artifact unexpectedly has a loaded waterway sidecar")
	}

	s.backfillTinyTilesWaterways(artifact)
	if got := s.tinyTilesWaterwayCount(); got != 2 {
		t.Fatalf("backfilled waterway count = %d, want 2", got)
	}
	if _, err := loadTinyTilesWaterwaySidecarForArtifact(tinyTilesWaterwaySidecarPath(dir), artifact); err != nil {
		t.Fatalf("backfilled sidecar does not match artifact: %v", err)
	}
}

// tinyTiles v2.3 can serve the postal-boundary sidecar directly. osmmini
// should activate that feature automatically when a postal-code build made
// the sidecar, rather than requiring a second in-memory PBF index.
func TestServeTinyTilesActivatesPostcodeSidecar(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	artifact := filepath.Join(dir, "basemap.ttiles")
	if _, err := tiles.ImportTiles(ctx, tinyTilesTestSource{}, artifact, &tiles.ImportOptions{
		BatchSize:      1,
		MaxMemoryBytes: 8 << 20,
		MinFreeBytes:   0,
	}); err != nil {
		t.Fatalf("create tinyTiles test artifact: %v", err)
	}
	postalSidecar := []byte(`{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"postcode":"94032","name":"Passau"},"geometry":{"type":"Polygon","coordinates":[[[13.4,48.55],[13.5,48.55],[13.5,48.60],[13.4,48.55]]]}}]}`)
	if err := os.WriteFile(filepath.Join(dir, "basemap.postcodes.geojson"), postalSidecar, 0o600); err != nil {
		t.Fatalf("write postcode sidecar: %v", err)
	}

	s := &server{tinyTilesDir: dir, tinyTilesReaders: 1, tinyTilesReaderMemory: 8 << 20, tinyTilesTileCacheBytes: 1 << 20}
	if err := s.installTinyTiles(artifact); err != nil {
		t.Fatalf("install tinyTiles test artifact: %v", err)
	}
	t.Cleanup(s.closeTinyTiles)

	response := httptest.NewRecorder()
	s.serveTinyTiles(response, httptest.NewRequest(http.MethodGet, "/tinytiles/postcode/search?q=940", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("postcode search status = %d: %s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "94032") {
		t.Fatalf("postcode search response = %s", response.Body.String())
	}
}

type tinyTilesTestSource struct{}

func (tinyTilesTestSource) Info(context.Context) (tiles.SourceInfo, error) {
	data := []byte{0x1a, 0x02, 0x08, 0x01}
	return tiles.SourceInfo{
		Name:         "osmmini-test",
		SourceBytes:  int64(len(data)),
		TileCount:    1,
		TileBytes:    int64(len(data)),
		MaxTileBytes: int64(len(data)),
		Metadata: map[string]string{
			"format":      "pbf",
			"minzoom":     "0",
			"maxzoom":     "0",
			"description": strings.Repeat("offline vector tiles ", 32),
		},
	}, nil
}

func (tinyTilesTestSource) ScanTiles(ctx context.Context, visit func(tiles.Tile) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return visit(tiles.Tile{Key: tiles.Key{}, Data: []byte{0x1a, 0x02, 0x08, 0x01}})
}
