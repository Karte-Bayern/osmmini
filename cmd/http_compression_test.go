package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestAcceptsGzip(t *testing.T) {
	for _, tc := range []struct {
		header []string
		want   bool
	}{
		{nil, false}, {[]string{"br, gzip, deflate"}, true},
		{[]string{"GZip; q=0.5"}, true}, {[]string{"*;q=0.8"}, true},
		{[]string{"*;q=1, gzip;q=0"}, false}, {[]string{"gzip;q=0", "*;q=1"}, false},
		{[]string{"gzip;q=0.0"}, false}, {[]string{"gzip;q=NaN"}, false},
		{[]string{"gzip;q=Inf"}, false}, {[]string{"gzip;q=2"}, false},
		{[]string{"gzip;q=-0.5"}, false}, {[]string{"gzip;q=garbage"}, false},
		{[]string{"gzip-not"}, false}, {[]string{"br", "gzip;q=1"}, true},
		{[]string{"identity;q=1,gzip;q=0.1"}, false},
		{[]string{"identity;q=0.1,gzip;q=1"}, true},
		{[]string{"identity;q=0,gzip"}, true},
		{[]string{"*;q=0,identity;q=1"}, false},
	} {
		if got := parseResponseEncodings(tc.header).prefersGzip(); got != tc.want {
			t.Errorf("Accept-Encoding %q: %v, want %v", tc.header, got, tc.want)
		}
	}
}

func TestJSONCompressionHonorsExplicitIdentityExclusion(t *testing.T) {
	for _, flush := range []bool{false, true} {
		for _, encoding := range []string{"gzip, identity;q=0", "*;q=0,gzip;q=1"} {
			handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = io.WriteString(w, `{"ok":`)
				if flush {
					if err := http.NewResponseController(w).Flush(); err != nil {
						t.Fatal(err)
					}
				}
				_, _ = io.WriteString(w, `true}`)
			}))
			req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
			req.Header.Set("Accept-Encoding", encoding)
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK || rec.Header().Get("Content-Encoding") != "gzip" {
				t.Fatalf("sent forbidden identity: %d %v", rec.Code, rec.Header())
			}
			reader, err := gzip.NewReader(rec.Body)
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := io.ReadAll(reader)
			_ = reader.Close()
			if err != nil || string(decoded) != `{"ok":true}` {
				t.Fatalf("changed small/streamed response: %q, %v", decoded, err)
			}
		}
	}
}

func TestJSONCompressionRejectsUnavailableUnencodedRepresentation(t *testing.T) {
	for _, tc := range []struct{ encoding, contentType string }{
		{"gzip;q=0,identity;q=0", "application/json"},
		{"*;q=0", "application/json"},
		{"br,identity;q=0", "application/json"},
		{"gzip,identity;q=0", "image/png"},
	} {
		handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", tc.contentType)
			w.Header().Set("Content-Length", "12")
			_, _ = io.WriteString(w, `{"ok":true}`)
		}))
		req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
		req.Header.Set("Accept-Encoding", tc.encoding)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusNotAcceptable || rec.Body.Len() != 0 || rec.Header().Get("Content-Length") != "0" {
			t.Fatalf("%s / %s: invalid negotiation fallback: %d %v", tc.encoding, tc.contentType, rec.Code, rec.Header())
		}
	}
}

func TestJSONCompressionKeepsBodylessStatuses(t *testing.T) {
	for _, status := range []int{http.StatusNoContent, http.StatusResetContent, http.StatusNotModified} {
		for _, contentType := range []string{"", "application/json"} {
			handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if contentType != "" {
					w.Header().Set("Content-Type", contentType)
				}
				w.WriteHeader(status)
			}))
			req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
			req.Header.Set("Accept-Encoding", "gzip,identity;q=0")
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != status || rec.Body.Len() != 0 || rec.Header().Get("Content-Encoding") != "" {
				t.Fatalf("bodyless status changed: %d %v %d bytes", rec.Code, rec.Header(), rec.Body.Len())
			}
		}
	}
}

func TestJSONCompressionPreservesPayloadAndHeaders(t *testing.T) {
	payload := []byte(`{"features":[` + strings.Repeat(`{"name":"Straße","coordinates":[12.1,48.2]},`, 1000) + `{}]}`)
	for _, contentType := range []string{"application/json; charset=utf-8", "application/geo+json"} {
		for _, chunkSize := range []int{len(payload), 127, 1} {
			t.Run(contentType+"/"+strconv.Itoa(chunkSize), func(t *testing.T) {
				handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Type", contentType)
					w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
					w.Header().Add("Vary", "Accept-Language")
					w.WriteHeader(http.StatusCreated)
					for start := 0; start < len(payload); start += chunkSize {
						if _, err := w.Write(payload[start:min(start+chunkSize, len(payload))]); err != nil {
							t.Fatal(err)
						}
					}
				}))
				req := httptest.NewRequest(http.MethodGet, "/api/v1/geo/pois", nil)
				req.Header.Set("Accept-Encoding", "gzip")
				rec := httptest.NewRecorder()
				handler.ServeHTTP(rec, req)
				result := rec.Result()
				defer result.Body.Close()
				if result.StatusCode != http.StatusCreated || result.Header.Get("Content-Encoding") != "gzip" || result.Header.Get("Content-Length") != "" {
					t.Fatalf("status/encoding: %d %v", result.StatusCode, result.Header)
				}
				if result.Header.Get("Content-Type") != contentType || strings.Join(result.Header.Values("Vary"), ",") != "Accept-Encoding,Accept-Language" {
					t.Fatalf("lost response headers: %v", result.Header)
				}
				reader, err := gzip.NewReader(result.Body)
				if err != nil {
					t.Fatal(err)
				}
				decoded, err := io.ReadAll(reader)
				if err != nil || !bytes.Equal(decoded, payload) {
					t.Fatalf("changed payload: %d bytes, %v", len(decoded), err)
				}
				if err := reader.Close(); err != nil {
					t.Fatal(err)
				}
				if rec.Body.Len() >= len(payload)/4 {
					t.Fatalf("expected repetitive GeoJSON to compress: %d -> %d", len(payload), rec.Body.Len())
				}
			})
		}
	}
}

func TestJSONCompressionBypassesOtherRepresentations(t *testing.T) {
	large := strings.Repeat("x", 2048)
	for _, tc := range []struct {
		name, method, path, accept, contentType, body string
		status                                        int
		headers                                       http.Header
	}{
		{name: "small", body: `{"ok":true}`},
		{name: "identity", accept: "identity", body: large},
		{name: "refused", accept: "gzip;q=0,*;q=1", body: large},
		{name: "head", method: http.MethodHead, body: large},
		{name: "static", path: "/static/app.js", body: large},
		{name: "binary", contentType: "image/png", body: large},
		{name: "already encoded", body: large, headers: http.Header{"Content-Encoding": {"br"}}},
		{name: "no transform", body: large, headers: http.Header{"Cache-Control": {"public, no-transform"}}},
		{name: "split no transform", body: large, headers: http.Header{"Cache-Control": {"public", "no-transform"}}},
		{name: "etag", body: large, headers: http.Header{"Etag": {`"unchanged"`}}},
		{name: "partial", body: large, status: http.StatusPartialContent},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.path == "" {
				tc.path = "/api/v1/test"
			}
			if tc.method == "" {
				tc.method = http.MethodGet
			}
			if tc.accept == "" {
				tc.accept = "gzip"
			}
			if tc.contentType == "" {
				tc.contentType = "application/json"
			}
			if tc.status == 0 {
				tc.status = http.StatusOK
			}
			handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				for key, values := range tc.headers {
					w.Header()[key] = values
				}
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			req := httptest.NewRequest(tc.method, tc.path, nil)
			req.Header.Set("Accept-Encoding", tc.accept)
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Body.String() != tc.body || rec.Code != tc.status || rec.Header().Get("Content-Encoding") == "gzip" {
				t.Fatalf("bypass changed response: %d %v %q", rec.Code, rec.Header(), rec.Body.String())
			}
		})
	}
}

func TestJSONCompressionFlushAndVary(t *testing.T) {
	for _, vary := range []string{"Accept-Encoding", "accept-encoding", "*"} {
		handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Vary", vary)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, "first")
			if err := http.NewResponseController(w).Flush(); err != nil {
				t.Fatal(err)
			}
			_, _ = io.WriteString(w, strings.Repeat("rest", 1024))
		}))
		req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
		req.Header.Set("Accept-Encoding", "gzip")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Header().Get("Vary") != vary || !rec.Flushed || rec.Header().Get("Content-Encoding") != "" || rec.Body.String() != "first"+strings.Repeat("rest", 1024) {
			t.Fatalf("flush/vary changed: %v", rec.Result())
		}
	}
}

func TestJSONCompressionFreezesStatusAndHeadersBeforeBufferedWrites(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Original", "yes")
			if explicit {
				w.WriteHeader(http.StatusOK)
			}
			_, _ = io.WriteString(w, "{}")
			w.WriteHeader(http.StatusInternalServerError)
			w.Header().Set("Content-Type", "image/png")
			w.Header().Set("X-Original", "too late")
			w.Header().Set("X-Late", "ignored")
			_, _ = io.WriteString(w, strings.Repeat(" ", 2048))
		}))
		req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
		req.Header.Set("Accept-Encoding", "gzip")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		header := rec.Result().Header
		if rec.Code != http.StatusOK || header.Get("Content-Type") != "application/json" || header.Get("X-Original") != "yes" || header.Get("X-Late") != "" || header.Get("Content-Encoding") != "gzip" {
			t.Fatalf("headers changed after WriteHeader/Write: %d %v", rec.Code, header)
		}
	}
}

func TestJSONCompressionKeepsHandlerVaryForBothEncodings(t *testing.T) {
	for _, encoding := range []string{"gzip", "identity"} {
		handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Vary", "Accept-Language")
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, strings.Repeat("x", 2048))
		}))
		req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
		req.Header.Set("Accept-Encoding", encoding)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		vary := strings.Join(rec.Result().Header.Values("Vary"), ",")
		if !strings.Contains(vary, "Accept-Encoding") || !strings.Contains(vary, "Accept-Language") {
			t.Fatalf("%s: lost Vary dimension: %s", encoding, vary)
		}
	}
}

func TestJSONCompressionPreservesDeclaredAndLateTrailers(t *testing.T) {
	for _, declared := range []bool{false, true} {
		for _, size := range []int{2, 2048} {
			handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				key := http.TrailerPrefix + "Checksum"
				if declared {
					w.Header().Set("Trailer", "Checksum")
					key = "Checksum"
				}
				_, _ = io.WriteString(w, strings.Repeat("x", size))
				w.Header().Set(key, "abc")
			}))
			req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
			req.Header.Set("Accept-Encoding", "gzip")
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Result().Trailer.Get("Checksum") != "abc" {
				t.Fatalf("declared=%v size=%d: lost trailer: %v", declared, size, rec.Result().Trailer)
			}
		}
	}
}

type compressionReaderFromRecorder struct {
	*httptest.ResponseRecorder
	copies int
}

func (w *compressionReaderFromRecorder) ReadFrom(reader io.Reader) (int64, error) {
	w.copies++
	return io.Copy(w.ResponseRecorder, reader)
}

func TestJSONCompressionPreservesDirectCopyForUncompressedFiles(t *testing.T) {
	payload := strings.Repeat("file data", 2048)
	for _, encoding := range []string{"gzip", "identity"} {
		handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/x-protobuf")
			_, err := io.Copy(w, struct{ io.Reader }{strings.NewReader(payload)})
			if err != nil {
				t.Fatal(err)
			}
		}))
		req := httptest.NewRequest(http.MethodGet, "/api/v1/geodata/tiles/0/0/0", nil)
		req.Header.Set("Accept-Encoding", encoding)
		rec := &compressionReaderFromRecorder{ResponseRecorder: httptest.NewRecorder()}
		handler.ServeHTTP(rec, req)
		if rec.copies != 1 || rec.Body.String() != payload {
			t.Fatalf("%s: optimized copy lost: copies=%d bytes=%d", encoding, rec.copies, rec.Body.Len())
		}
	}
	// Copying a JSON file must instead traverse the compression path.
	handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/geo+json")
		_, _ = io.Copy(w, struct{ io.Reader }{strings.NewReader(payload)})
	}))
	req := httptest.NewRequest(http.MethodGet, "/api/v1/geodata/layers/example", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec := &compressionReaderFromRecorder{ResponseRecorder: httptest.NewRecorder()}
	handler.ServeHTTP(rec, req)
	if rec.copies != 0 || rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatal("compressed file bypassed gzip")
	}
	reader, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	decoded, err := io.ReadAll(reader)
	if err != nil || string(decoded) != payload {
		t.Fatalf("compressed file changed: %v", err)
	}
}

func compressionBenchmarkPayload() []byte {
	features := make([]map[string]any, 2000)
	for i := range features {
		features[i] = map[string]any{"type": "Feature", "geometry": map[string]any{"type": "Point", "coordinates": []float64{12 + float64(i)/10000, 48.5}}, "properties": map[string]any{"name": "Teststraße " + strconv.Itoa(i)}}
	}
	payload, _ := json.Marshal(map[string]any{"type": "FeatureCollection", "features": features})
	return payload
}

type compressionBenchmarkWriter struct {
	header http.Header
	bytes  int
}

func (w *compressionBenchmarkWriter) Header() http.Header { return w.header }
func (w *compressionBenchmarkWriter) WriteHeader(int)     {}
func (w *compressionBenchmarkWriter) Write(data []byte) (int, error) {
	w.bytes += len(data)
	return len(data), nil
}

func BenchmarkJSONResponseCompression(b *testing.B) {
	payload := compressionBenchmarkPayload()
	handler := withJSONCompression(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/geo+json")
		_, _ = w.Write(payload)
	}))
	for _, encoding := range []string{"identity", "gzip"} {
		b.Run(encoding, func(b *testing.B) {
			req := httptest.NewRequest(http.MethodGet, "/api/v1/geo/pois", nil)
			req.Header.Set("Accept-Encoding", encoding)
			w := &compressionBenchmarkWriter{header: make(http.Header)}
			b.ReportAllocs()
			b.SetBytes(int64(len(payload)))
			for b.Loop() {
				clear(w.header)
				w.bytes = 0
				handler.ServeHTTP(w, req)
			}
			b.ReportMetric(float64(w.bytes), "wire-B/op")
		})
	}
}
