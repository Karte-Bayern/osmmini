package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type tileRoundTripper func(*http.Request) (*http.Response, error)

func (f tileRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func tileResponse(data []byte) *http.Response {
	return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: int64(len(data)), Body: io.NopCloser(bytes.NewReader(data))}
}

func testTileProxy(t *testing.T, transport http.RoundTripper) *TileCache {
	t.Helper()
	cache := NewTileCache(TileSettings{CacheDir: t.TempDir(), Upstream: "https://tiles.example.test/{z}/{x}/{y}.png", UserAgent: "OSMmini tile test"})
	cache.client = &http.Client{Transport: transport, Timeout: 5 * time.Second}
	t.Cleanup(cache.Close)
	return cache
}

func startTileRequest(cache *TileCache, ctx context.Context) <-chan *httptest.ResponseRecorder {
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		w := httptest.NewRecorder()
		cache.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/tiles/1/0/0.png", nil).WithContext(ctx))
		done <- w
	}()
	return done
}

func waitTileResponse(t *testing.T, done <-chan *httptest.ResponseRecorder, status int, data []byte) {
	t.Helper()
	select {
	case response := <-done:
		if response.Code != status || data != nil && !bytes.Equal(response.Body.Bytes(), data) {
			t.Fatalf("response: status %d, %d bytes; want %d, %d bytes", response.Code, response.Body.Len(), status, len(data))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("tile request did not complete")
	}
}

func waitTileWaiters(t *testing.T, cache *TileCache, count int) {
	t.Helper()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for {
		cache.mu.RLock()
		waiters := 0
		for _, flight := range cache.flights {
			waiters += flight.waiters
		}
		cache.mu.RUnlock()
		if waiters == count {
			return
		}
		select {
		case <-ticker.C:
		case <-deadline.C:
			t.Fatalf("flight waiters: %d, want %d", waiters, count)
		}
	}
}

func TestTileProxyCoalescesConcurrentMissesAndWarmsBothCaches(t *testing.T) {
	data := encodedPNG(t)
	release := make(chan struct{})
	var requests atomic.Int32
	cache := testTileProxy(t, tileRoundTripper(func(r *http.Request) (*http.Response, error) {
		requests.Add(1)
		if r.URL.String() != "https://tiles.example.test/1/0/0.png" || r.Header.Get("User-Agent") != "OSMmini tile test" || r.Method != http.MethodGet {
			t.Errorf("upstream request: %s %s, UA %q", r.Method, r.URL, r.Header.Get("User-Agent"))
		}
		select {
		case <-release:
			return tileResponse(data), nil
		case <-r.Context().Done():
			return nil, r.Context().Err()
		}
	}))
	var responses []<-chan *httptest.ResponseRecorder
	for range 24 {
		responses = append(responses, startTileRequest(cache, t.Context()))
	}
	waitTileWaiters(t, cache, len(responses))
	close(release)
	for _, response := range responses {
		waitTileResponse(t, response, http.StatusOK, data)
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("24 concurrent requests caused %d upstream fetches, want 1", got)
	}
	if stats := cache.Stats(); stats["fetches"] != 1 || stats["errors"] != 0 {
		t.Fatalf("stats: %v", stats)
	}
	// A simulated restart of L1 uses the published disk file, never upstream.
	cache.mu.Lock()
	cache.mem = make(map[tileCacheKey]*tileMemEntry)
	cache.mu.Unlock()
	waitTileResponse(t, startTileRequest(cache, t.Context()), http.StatusOK, data)
	if requests.Load() != 1 || cache.Stats()["disk_hits"] != 1 {
		t.Fatalf("disk cache was not used: fetches %d, stats %v", requests.Load(), cache.Stats())
	}
	head := httptest.NewRecorder()
	cache.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/tiles/1/0/0.png", nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Length") != strconv.Itoa(len(data)) || head.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("HEAD response: %d, %v, body %d", head.Code, head.Header(), head.Body.Len())
	}
}

func TestTileProxyCancellationDoesNotCancelOtherWaiters(t *testing.T) {
	data := encodedPNG(t)
	release := make(chan struct{})
	cancelled := make(chan struct{}, 1)
	cache := testTileProxy(t, tileRoundTripper(func(r *http.Request) (*http.Response, error) {
		select {
		case <-release:
			return tileResponse(data), nil
		case <-r.Context().Done():
			cancelled <- struct{}{}
			return nil, r.Context().Err()
		}
	}))
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	leader := startTileRequest(cache, ctx)
	waitTileWaiters(t, cache, 1)
	follower := startTileRequest(cache, t.Context())
	waitTileWaiters(t, cache, 2)
	cancel()
	waitTileResponse(t, leader, http.StatusBadGateway, nil)
	waitTileWaiters(t, cache, 1)
	select {
	case <-cancelled:
		t.Fatal("one cancelled browser aborted another browser's tile")
	default:
	}
	close(release)
	waitTileResponse(t, follower, http.StatusOK, data)
}

func TestTileProxyLastCancellationAbortsUpstreamAndAllowsRetry(t *testing.T) {
	data := encodedPNG(t)
	entered := make(chan struct{})
	cancelled := make(chan struct{})
	var requests atomic.Int32
	cache := testTileProxy(t, tileRoundTripper(func(r *http.Request) (*http.Response, error) {
		if requests.Add(1) == 1 {
			close(entered)
			<-r.Context().Done()
			close(cancelled)
			return nil, r.Context().Err()
		}
		return tileResponse(data), nil
	}))
	ctx, cancel := context.WithCancel(t.Context())
	first := startTileRequest(cache, ctx)
	waitTileWaiters(t, cache, 1)
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("upstream request did not start")
	}
	cancel()
	waitTileResponse(t, first, http.StatusBadGateway, nil)
	select {
	case <-cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("abandoned download was not cancelled")
	}
	waitTileResponse(t, startTileRequest(cache, t.Context()), http.StatusOK, data)
	if requests.Load() != 2 {
		t.Fatalf("retry requests: %d, want 2", requests.Load())
	}
}

func TestTileProxyCloseCancelsActiveDownload(t *testing.T) {
	entered := make(chan struct{})
	cache := testTileProxy(t, tileRoundTripper(func(r *http.Request) (*http.Response, error) {
		close(entered)
		<-r.Context().Done()
		return nil, r.Context().Err()
	}))
	response := startTileRequest(cache, t.Context())
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("upstream request did not start")
	}
	cache.Close()
	cache.Close()
	waitTileResponse(t, response, http.StatusBadGateway, nil)
}

func TestTileProxyRejectsOversizedResponseWithoutCachingPrefix(t *testing.T) {
	data := encodedPNG(t)
	for _, length := range []int64{-1, maxProxyTileBytes + 1} {
		t.Run(strconv.FormatInt(length, 10), func(t *testing.T) {
			var requests atomic.Int32
			cache := testTileProxy(t, tileRoundTripper(func(*http.Request) (*http.Response, error) {
				if requests.Add(1) > 1 {
					return tileResponse(data), nil
				}
				body := io.MultiReader(bytes.NewReader(data), io.LimitReader(zeroTileReader{}, maxProxyTileBytes+1-int64(len(data))))
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: length, Body: io.NopCloser(body)}, nil
			}))
			waitTileResponse(t, startTileRequest(cache, t.Context()), http.StatusBadGateway, nil)
			waitTileResponse(t, startTileRequest(cache, t.Context()), http.StatusOK, data)
			if requests.Load() != 2 || cache.Stats()["errors"] != 1 {
				t.Fatalf("oversize response was cached: requests %d, stats %v", requests.Load(), cache.Stats())
			}
		})
	}
}

func TestTileProxyContentLengthValidation(t *testing.T) {
	for _, test := range []struct {
		name   string
		length int64
		body   string
		ok     bool
	}{
		{"known", 4, "tile", true},
		{"chunked", -1, "tile", true},
		{"short", 5, "tile", false},
		{"long", 3, "tile", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			response := &http.Response{ContentLength: test.length, Body: io.NopCloser(strings.NewReader(test.body))}
			body, err := readProxyTileBody(response)
			if (err == nil) != test.ok || test.ok && string(body) != test.body {
				t.Fatalf("body %q, %v; want success %v", body, err, test.ok)
			}
		})
	}
}

type zeroTileReader struct{}

func (zeroTileReader) Read(b []byte) (int, error) {
	clear(b)
	return len(b), nil
}

func TestTileProxyReusesConnectionAfterShortUpstreamError(t *testing.T) {
	data := encodedPNG(t)
	var connections atomic.Int32
	upstream := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/0.png") {
			http.Error(w, "not yet available", http.StatusNotFound)
			return
		}
		_, _ = w.Write(data)
	}))
	upstream.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	upstream.Start()
	defer upstream.Close()
	transport := http.DefaultTransport.(*http.Transport).Clone()
	defer transport.CloseIdleConnections()
	cache := testTileProxy(t, transport)
	cfg, _, _ := cache.cfgCopy()
	cfg.Upstream = upstream.URL + "/{z}/{x}/{y}.png"
	cache.Update(cfg)
	for _, tile := range []struct {
		path   string
		status int
	}{{"/tiles/2/0/0.png", http.StatusBadGateway}, {"/tiles/2/0/1.png", http.StatusOK}, {"/tiles/2/0/2.png", http.StatusOK}} {
		w := httptest.NewRecorder()
		cache.ServeHTTP(w, httptest.NewRequest(http.MethodGet, tile.path, nil))
		if w.Code != tile.status {
			t.Fatalf("%s: status %d, want %d", tile.path, w.Code, tile.status)
		}
	}
	if connections.Load() != 1 {
		t.Fatalf("three requests, including one error, opened %d connections; want 1", connections.Load())
	}
}

func TestTileProxyDiskCacheBoundsAndAtomicReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "z", "x", "0.tile")
	data := encodedPNG(t)
	if err := writeCachedTile(path, data); err != nil {
		t.Fatal(err)
	}
	if got, contentType, ok := readCachedTile(path); !ok || !bytes.Equal(got, data) || contentType != "image/png" {
		t.Fatalf("disk read: %d bytes, %s, %v", len(got), contentType, ok)
	}
	if err := os.Truncate(path, maxProxyTileBytes+1); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := readCachedTile(path); ok {
		t.Fatal("oversized disk entry accepted")
	}
	if err := writeCachedTile(path, data); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-tileDiskCacheTTL - time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := readCachedTile(path); ok {
		t.Fatal("expired disk entry accepted")
	}
	files, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(files) != 1 || files[0].Name() != "0.tile" {
		t.Fatalf("temporary cache files leaked: %v, %v", files, err)
	}
}

func TestTileProxyConcurrentDiskReadersSeeCompleteFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "0.tile")
	first, second := encodedPNG(t), encodedJPEG(t)
	if err := writeCachedTile(path, first); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			for range 100 {
				data, _, ok := readCachedTile(path)
				if !ok || !bytes.Equal(data, first) && !bytes.Equal(data, second) {
					t.Errorf("read partial disk cache entry (%d bytes, valid %v)", len(data), ok)
					return
				}
			}
		})
	}
	for i := range 100 {
		data := first
		if i%2 == 0 {
			data = second
		}
		if err := writeCachedTile(path, data); err != nil {
			t.Error(err)
			break
		}
	}
	wg.Wait()
}
