package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	tinytiles "github.com/Karte-Bayern/tinyTiles/v2"
	tinytilesserver "github.com/Karte-Bayern/tinyTiles/v2/server"
)

// BenchmarkServeRealTinyTile includes osmmini's mount rewriting and the warm
// offline HTTP handler, but excludes artifact opening and network transfer.
func BenchmarkServeRealTinyTile(b *testing.B) {
	artifact := os.Getenv("OSMMINI_REAL_TILE_ARTIFACT")
	if artifact == "" {
		b.Skip("set OSMMINI_REAL_TILE_ARTIFACT to a Niederbayern .ttiles artifact")
	}
	dataset, err := tinytiles.Open(context.Background(), artifact, tinytiles.OpenOptions{Readers: 1, MaxMemoryBytes: 8 << 20})
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = dataset.Close() })
	offline, err := tinytilesserver.New(tinytilesserver.Config{Dataset: dataset, DatasetID: "benchmark", MountPath: "/tinytiles", TileCacheBytes: 1 << 20})
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(offline.Close)
	s := &server{tinyTilesHandler: offline.Handler()}
	req := httptest.NewRequest(http.MethodGet, "/tinytiles/tiles/14/8804/5656.mvt", nil)
	req.Header.Set("Accept", "application/vnd.mapbox-vector-tile,*/*")
	req.Header.Set("Accept-Encoding", "gzip, deflate, br")
	req.Header.Set("User-Agent", "OSMmini tile benchmark")
	req.Header.Set("Referer", "http://localhost/")
	req.Header.Set("Sec-Fetch-Dest", "empty")
	req.Header.Set("Sec-Fetch-Mode", "cors")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	warm := httptest.NewRecorder()
	s.serveTinyTiles(warm, req)
	if warm.Code != http.StatusOK || warm.Body.Len() == 0 {
		b.Fatalf("Passau tile: status %d, %d bytes", warm.Code, warm.Body.Len())
	}
	w := tileBenchmarkWriter{header: make(http.Header)}
	b.SetBytes(int64(warm.Body.Len()))
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		s.serveTinyTiles(w, req)
	}
}
