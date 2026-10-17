package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

type tileBenchmarkWriter struct{ header http.Header }

func (w tileBenchmarkWriter) Header() http.Header         { return w.header }
func (w tileBenchmarkWriter) WriteHeader(int)             {}
func (w tileBenchmarkWriter) Write(b []byte) (int, error) { return len(b), nil }

func BenchmarkTileProxyMemoryHit(b *testing.B) {
	cfg := TileSettings{CacheDir: b.TempDir(), Upstream: "https://maps.example.test/{z}/{x}/{y}.png"}
	cache := NewTileCache(cfg)
	defer cache.Close()
	cache.setInMem(tileCacheKey{source: tileSourceNamespace(cfg), z: 14, x: 8529, y: 5974}, []byte("cached tile"), "image/png")
	req := httptest.NewRequest(http.MethodGet, "/tiles/14/8529/5974.png", nil)
	w := tileBenchmarkWriter{header: make(http.Header)}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		cache.ServeHTTP(w, req)
	}
}

func BenchmarkTileDiskCacheRead(b *testing.B) {
	data := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, (64<<10)-8)...)
	path := filepath.Join(b.TempDir(), "tile")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for b.Loop() {
		got, contentType, ok := readCachedTile(path)
		if !ok || len(got) != len(data) || contentType != "image/png" {
			b.Fatalf("disk tile: %d, %s, %v", len(got), contentType, ok)
		}
	}
}

func BenchmarkTileProxyReadBody(b *testing.B) {
	data := bytes.Repeat([]byte{1}, 64<<10)
	for _, knownLength := range []bool{true, false} {
		name := "Chunked"
		length := int64(-1)
		if knownLength {
			name, length = "ContentLength", int64(len(data))
		}
		b.Run(name, func(b *testing.B) {
			reader := bytes.NewReader(data)
			response := &http.Response{ContentLength: length, Body: io.NopCloser(reader)}
			b.ReportAllocs()
			b.SetBytes(int64(len(data)))
			b.ResetTimer()
			for b.Loop() {
				reader.Reset(data)
				body, err := readProxyTileBody(response)
				if err != nil || len(body) != len(data) {
					b.Fatalf("body: %d bytes, %v", len(body), err)
				}
			}
		})
	}
}
