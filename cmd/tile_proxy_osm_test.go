package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestTileProxyNeverProxiesPublicOSMTiles(t *testing.T) {
	data := encodedPNG(t)
	for _, mapType := range []string{"raster", "vector", "wms", "raster-direct"} {
		t.Run(mapType, func(t *testing.T) {
			// Deliberately bypass DefaultSettings/normalizeTileSettings. A vector
			// source may retain an OSM raster fallback while legacy integrations
			// may construct a plain raster proxy directly.
			cfg := TileSettings{
				CacheDir: t.TempDir(), MapType: mapType,
				Upstream:  "https://TILE.openstreetmap.org/{z}/{x}/{y}.png",
				WMSLayers: "unused",
			}
			cache := NewTileCache(cfg)
			defer cache.Close()
			var requests atomic.Int32
			cache.client.Transport = tileRoundTripper(func(*http.Request) (*http.Response, error) {
				requests.Add(1)
				return tileResponse(data), nil
			})
			for _, cached := range []bool{false, true} {
				if cached {
					cache.setInMem(tileCacheKey{source: tileSourceNamespace(cfg), z: 1, x: 0, y: 0}, data, "image/png")
				}
				for _, method := range []string{http.MethodGet, http.MethodHead} {
					w := httptest.NewRecorder()
					cache.ServeHTTP(w, httptest.NewRequest(method, "/tiles/1/0/0.png", nil))
					if w.Code != http.StatusNotFound {
						t.Fatalf("%s, cached %v: status %d, want 404", method, cached, w.Code)
					}
				}
			}
			if requests.Load() != 0 {
				t.Fatalf("public OSM source reached the proxy upstream %d times", requests.Load())
			}
			if stats := cache.Stats(); stats["fetches"] != 0 || stats["mem_hits"] != 0 || stats["disk_hits"] != 0 {
				t.Fatalf("public OSM source reached a proxy cache tier: %v", stats)
			}
		})
	}
}

func TestTileProxySourceUpdateRefreshesDirectOnlyGuard(t *testing.T) {
	data := encodedPNG(t)
	var requests atomic.Int32
	cache := testTileProxy(t, tileRoundTripper(func(*http.Request) (*http.Response, error) {
		requests.Add(1)
		return tileResponse(data), nil
	}))
	for _, step := range []struct {
		mapType, upstream string
		status, requests  int
	}{
		{"raster", "https://tiles.example.test/{z}/{x}/{y}.png", 200, 1},
		{"raster", "https://tile.openstreetmap.org/{z}/{x}/{y}.png", 404, 1},
		{"vector", "https://tiles.example.test/{z}/{x}/{y}.png", 200, 2},
		{"raster-direct", "https://tiles.example.test/{z}/{x}/{y}.png", 404, 2},
		{"raster", "https://tiles.example.test/{z}/{x}/{y}.png", 200, 2},
	} {
		cfg, _, _ := cache.cfgCopy()
		cfg.MapType, cfg.Upstream = step.mapType, step.upstream
		cache.Update(cfg)
		w := httptest.NewRecorder()
		cache.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/tiles/1/0/0.png", nil))
		if w.Code != step.status || requests.Load() != int32(step.requests) {
			t.Fatalf("%s %s: status %d, fetches %d; want %d, %d", step.mapType, step.upstream, w.Code, requests.Load(), step.status, step.requests)
		}
	}
}
