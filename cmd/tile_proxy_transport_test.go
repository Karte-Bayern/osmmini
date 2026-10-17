package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestTileProxyTransportKeepsDefaultsAndOwnsItsPool(t *testing.T) {
	base := http.DefaultTransport.(*http.Transport)
	client, owned := newTileHTTPClient(base)
	defer owned.CloseIdleConnections()
	if owned == nil || owned == base || client.Transport != owned {
		t.Fatal("tile client must own a clone of the configured transport")
	}
	if client.Timeout != 25*time.Second || owned.MaxIdleConnsPerHost < 32 || owned.MaxIdleConns > 0 && owned.MaxIdleConns < 32 {
		t.Fatalf("tile client settings: timeout %v, idle per host %d, idle total %d", client.Timeout, owned.MaxIdleConnsPerHost, owned.MaxIdleConns)
	}
	if owned.ForceAttemptHTTP2 != base.ForceAttemptHTTP2 || owned.TLSHandshakeTimeout != base.TLSHandshakeTimeout || owned.IdleConnTimeout != base.IdleConnTimeout || (owned.DialContext == nil) != (base.DialContext == nil) || (owned.Proxy == nil) != (base.Proxy == nil) {
		t.Fatal("transport clone discarded HTTP/2, dial, TLS, proxy or idle defaults")
	}
	configured := base.Clone()
	configured.MaxIdleConnsPerHost = 64
	configured.MaxIdleConns = 8
	_, larger := newTileHTTPClient(configured)
	defer larger.CloseIdleConnections()
	if larger.MaxIdleConnsPerHost != 64 || larger.MaxIdleConns < 32 || configured.MaxIdleConns != 8 {
		t.Fatal("clone mutated source settings or reduced a configured host pool")
	}
	var customCalls atomic.Int32
	custom := tileRoundTripper(func(*http.Request) (*http.Response, error) {
		customCalls.Add(1)
		return tileResponse(nil), nil
	})
	client, owned = newTileHTTPClient(custom)
	if owned != nil || client.Transport == nil || client.Timeout != 25*time.Second {
		t.Fatal("custom RoundTripper was replaced or acquired as an owned transport")
	}
	response, err := client.Get("https://tiles.example.test/0/0/0.png")
	if err != nil || customCalls.Load() != 1 {
		t.Fatalf("custom transport was not used: %d calls, %v", customCalls.Load(), err)
	}
	response.Body.Close()
}

func TestTileProxyReusesConnectionsAcrossDifferentTileBursts(t *testing.T) {
	const count = 16
	data := encodedPNG(t)
	var connections, requests atomic.Int32
	var arrivals [2]atomic.Int32
	gates := [2]chan struct{}{make(chan struct{}), make(chan struct{})}
	closed := make(chan struct{}, 2*count)
	upstream := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 1 {
			t.Errorf("test requires HTTP/1, got %s", r.Proto)
		}
		requests.Add(1)
		y, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/6/0/"), ".png"))
		if err != nil || y < 0 || y >= 2*count {
			t.Errorf("unexpected tile URL: %s", r.URL)
			http.Error(w, "unexpected tile", http.StatusBadRequest)
			return
		}
		burst := y / count
		if arrivals[burst].Add(1) == count {
			close(gates[burst])
		}
		select {
		case <-gates[burst]:
			_, _ = w.Write(data)
		case <-r.Context().Done():
		}
	}))
	upstream.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		switch state {
		case http.StateNew:
			connections.Add(1)
		case http.StateClosed:
			closed <- struct{}{}
		}
	}
	upstream.Start()
	defer upstream.Close()
	cache := NewTileCache(TileSettings{CacheDir: t.TempDir(), Upstream: upstream.URL + "/{z}/{x}/{y}.png"})
	defer cache.Close()
	for burst := range 2 {
		var responses []<-chan *httptest.ResponseRecorder
		for tile := range count {
			done := make(chan *httptest.ResponseRecorder, 1)
			responses = append(responses, done)
			go func(y int) {
				w := httptest.NewRecorder()
				cache.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/tiles/6/0/"+strconv.Itoa(y)+".png", nil))
				done <- w
			}(burst*count + tile)
		}
		for _, response := range responses {
			waitTileResponse(t, response, http.StatusOK, data)
		}
		if connections.Load() != count {
			t.Fatalf("burst %d: %d connections, want %d reused connections", burst+1, connections.Load(), count)
		}
	}
	if requests.Load() != 2*count || cache.Stats()["fetches"] != 2*count {
		t.Fatalf("test did not fetch 32 distinct tiles: requests %d, stats %v", requests.Load(), cache.Stats())
	}
	cache.Close()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for range count {
		select {
		case <-closed:
		case <-deadline.C:
			t.Fatal("cache.Close did not close its idle HTTP connections")
		}
	}
}

func TestTileProxyStalledErrorBodyHasBoundedDrain(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	cache := NewTileCache(TileSettings{CacheDir: t.TempDir(), Upstream: upstream.URL + "/{z}/{x}/{y}.png"})
	defer cache.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	started := time.Now()
	response := startTileRequest(cache, ctx)
	select {
	case w := <-response:
		if w.Code != http.StatusBadGateway || time.Since(started) > 2*time.Second {
			t.Fatalf("stalled error: status %d, duration %v", w.Code, time.Since(started))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("stalled upstream error kept the tile request open")
	}
}
