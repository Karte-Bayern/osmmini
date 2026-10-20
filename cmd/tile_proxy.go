package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxProxyTileBytes = 8 << 20

// A viewport fetches many different tiles concurrently. Keep enough HTTP/1
// connections idle for the next viewport rather than inheriting the default
// limit of two per host. Clone once so each cache owns only its own pool;
// HTTP/2, proxy, dial and TLS defaults remain those of the configured transport.
func newTileHTTPClient(base http.RoundTripper) (*http.Client, *http.Transport) {
	var owned *http.Transport
	if transport, ok := base.(*http.Transport); ok && transport != nil {
		owned = transport.Clone()
		owned.MaxIdleConnsPerHost = max(32, owned.MaxIdleConnsPerHost)
		if owned.MaxIdleConns > 0 && owned.MaxIdleConns < 32 {
			owned.MaxIdleConns = 32
		}
		base = owned
	}
	return &http.Client{Transport: base, Timeout: 25 * time.Second}, owned
}

var tileCacheControl = fmt.Sprintf("public, max-age=%d, stale-while-revalidate=3600", int(tileBrowserMaxAge.Seconds()))

type tileResult struct {
	data         []byte
	contentType  string
	errorMessage string
}

type tileFlight struct {
	done    chan struct{}
	cancel  context.CancelFunc
	waiters int // protected by TileCache.mu
	result  tileResult
}

// loadTile coalesces disk lookups and upstream downloads for the same source
// and coordinates. Each browser can cancel independently; the shared request is
// cancelled as soon as its final waiter leaves.
func (tc *TileCache) loadTile(ctx context.Context, cfg TileSettings, key tileCacheKey) tileResult {
	if ctx.Err() != nil {
		return tileResult{errorMessage: "tile upstream error"}
	}
	tc.mu.Lock()
	// A previous flight may have populated L1 between ServeHTTP's lookup and
	// acquiring this lock. Avoid starting a redundant disk read in that gap.
	if e := tc.mem[key]; e != nil && !time.Now().After(e.expiresAt) {
		tc.stats.memHits.Add(1)
		tc.mu.Unlock()
		return tileResult{data: e.data, contentType: e.contentType}
	}
	flight := tc.flights[key]
	if flight == nil {
		shared, cancel := context.WithCancel(context.WithoutCancel(ctx))
		flight = &tileFlight{done: make(chan struct{}), cancel: cancel}
		tc.flights[key] = flight
		go tc.fillTile(shared, cfg, key, flight)
	}
	flight.waiters++
	tc.mu.Unlock()

	select {
	case <-ctx.Done():
		tc.leaveTileFlight(key, flight)
		return tileResult{errorMessage: "tile upstream error"}
	case <-flight.done:
		tc.leaveTileFlight(key, flight)
		return flight.result
	}
}

func (tc *TileCache) leaveTileFlight(key tileCacheKey, flight *tileFlight) {
	tc.mu.Lock()
	defer tc.mu.Unlock()
	flight.waiters--
	if flight.waiters == 0 {
		flight.cancel()
		// Drop an abandoned flight immediately so a later request gets a fresh
		// context rather than joining work whose cancellation is already set.
		if tc.flights[key] == flight {
			delete(tc.flights, key)
		}
	}
}

func (tc *TileCache) fillTile(ctx context.Context, cfg TileSettings, key tileCacheKey, flight *tileFlight) {
	result := tc.readOrFetchTile(ctx, cfg, key)
	tc.mu.Lock()
	flight.result = result
	if tc.flights[key] == flight {
		delete(tc.flights, key)
	}
	close(flight.done)
	tc.mu.Unlock()
	flight.cancel()
}

func (tc *TileCache) tileError(message string) tileResult {
	tc.mu.Lock()
	tc.stats.errors++
	tc.mu.Unlock()
	return tileResult{errorMessage: message}
}

func (tc *TileCache) readOrFetchTile(ctx context.Context, cfg TileSettings, key tileCacheKey) tileResult {
	cachePath := filepath.Join(cfg.CacheDir, key.source, strconv.Itoa(key.z), strconv.Itoa(key.x), strconv.Itoa(key.y)+".tile")
	if data, contentType, ok := readCachedTile(cachePath); ok {
		if ctx.Err() != nil {
			return tc.tileError("tile upstream error")
		}
		tc.mu.Lock()
		tc.stats.diskHits++
		tc.mu.Unlock()
		tc.setInMem(key, data, contentType)
		return tileResult{data: data, contentType: contentType}
	}

	upstream := cfg.Upstream
	if normalizedMapType(cfg.MapType) == "wms" {
		minx, miny, maxx, maxy := tileBBox3857(key.z, key.x, key.y)
		var err error
		upstream, err = buildWMSGetMapURL(upstream, cfg.WMSLayers, minx, miny, maxx, maxy)
		if err != nil {
			return tc.tileError("tile upstream error")
		}
	} else {
		upstream = strings.ReplaceAll(upstream, "{z}", strconv.Itoa(key.z))
		upstream = strings.ReplaceAll(upstream, "{x}", strconv.Itoa(key.x))
		upstream = strings.ReplaceAll(upstream, "{y}", strconv.Itoa(key.y))
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, upstream, nil)
	if err != nil {
		return tc.tileError("tile upstream error")
	}
	if cfg.UserAgent != "" {
		req.Header.Set("User-Agent", cfg.UserAgent)
	}
	resp, err := tc.client.Do(req)
	if err != nil {
		return tc.tileError("tile upstream error")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// Preserve connection reuse for short errors without waiting for a
		// stalled error stream for the full tile-client timeout.
		drainRemoteBody(resp)
		return tc.tileError("tile upstream non-200")
	}
	data, err := readProxyTileBody(resp)
	if err != nil || len(data) == 0 {
		return tc.tileError("tile read error")
	}
	contentType, ok := tileImageContentType(data)
	if !ok {
		return tc.tileError("tile upstream did not return an image")
	}
	if ctx.Err() != nil {
		return tc.tileError("tile upstream error")
	}
	// Readers only see complete cache files, including while another process
	// refreshes the same expired tile. Cache write failures remain non-fatal.
	_ = writeCachedTile(cachePath, data)
	tc.setInMem(key, data, contentType)
	tc.mu.Lock()
	tc.stats.fetches++
	tc.mu.Unlock()
	return tileResult{data: data, contentType: contentType}
}

func readProxyTileBody(resp *http.Response) ([]byte, error) {
	if resp.ContentLength > maxProxyTileBytes {
		return nil, errors.New("tile exceeds 8 MiB")
	}
	if resp.ContentLength >= 0 {
		// Normal raster responses supply Content-Length. Allocate exactly once
		// instead of growing io.ReadAll's buffer through multiple copies.
		data := make([]byte, int(resp.ContentLength))
		if _, err := io.ReadFull(resp.Body, data); err != nil {
			return nil, err
		}
		var extra [1]byte
		if n, err := io.ReadFull(resp.Body, extra[:]); n != 0 || err != io.EOF {
			return nil, errors.New("tile body differs from content length")
		}
		return data, nil
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxProxyTileBytes+1))
	if len(data) > maxProxyTileBytes {
		return nil, errors.New("tile exceeds 8 MiB")
	}
	return data, err
}

func readCachedTile(path string) ([]byte, string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", false
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxProxyTileBytes || time.Since(info.ModTime()) > tileDiskCacheTTL {
		return nil, "", false
	}
	b := make([]byte, int(info.Size()))
	if _, err := io.ReadFull(f, b); err != nil {
		return nil, "", false
	}
	var extra [1]byte
	if n, err := f.Read(extra[:]); n != 0 || err != io.EOF {
		return nil, "", false
	}
	contentType, ok := tileImageContentType(b)
	if !ok {
		return nil, "", false
	}
	return b, contentType, true
}

func writeCachedTile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".tile-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Chmod(0o644); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
