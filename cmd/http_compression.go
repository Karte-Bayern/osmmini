package main

import (
	"compress/gzip"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

const jsonCompressionMinimum = 1024

var jsonGzipWriters = sync.Pool{New: func() any {
	w, _ := gzip.NewWriterLevel(io.Discard, gzip.BestSpeed)
	return w
}}

// The API's large route and map responses are compressible text. Keep binary
// tiles, downloads, range requests and small status responses on their existing
// path. A fixed-size prefix suffices to decide; never buffer the whole response.
func withJSONCompression(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/v1/") {
			next.ServeHTTP(w, r)
			return
		}
		addEncodingVary(w.Header())
		encoding := parseResponseEncodings(r.Header.Values("Accept-Encoding"))
		compressed := &jsonCompressionWriter{ResponseWriter: w,
			disabled:          r.Method == http.MethodHead || r.Header.Get("Range") != "" || !encoding.prefersGzip(),
			identityForbidden: encoding.identity == 0,
			gzipRequired:      encoding.identity == 0 && encoding.gzip > 0,
			head:              r.Method == http.MethodHead}
		defer compressed.release()
		next.ServeHTTP(compressed, r)
		compressed.finish()
	})
}

type responseEncodings struct {
	gzip, identity   float64
	explicitIdentity bool
}

func (e responseEncodings) prefersGzip() bool {
	return e.gzip > 0 && (!e.explicitIdentity || e.gzip >= e.identity)
}

func parseResponseEncodings(headers []string) responseEncodings {
	explicit, wildcard, identity := -1.0, -1.0, -1.0
	for _, header := range headers {
		for _, entry := range strings.Split(header, ",") {
			name, parameters, _ := strings.Cut(strings.TrimSpace(entry), ";")
			name = strings.TrimSpace(name)
			if !strings.EqualFold(name, "gzip") && !strings.EqualFold(name, "identity") && name != "*" {
				continue
			}
			quality := 1.0
			for _, parameter := range strings.Split(parameters, ";") {
				key, value, ok := strings.Cut(strings.TrimSpace(parameter), "=")
				if !ok || !strings.EqualFold(strings.TrimSpace(key), "q") {
					continue
				}
				q, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
				if err != nil || !(q >= 0 && q <= 1) {
					quality = 0
					break
				}
				quality = q
			}
			if name == "*" {
				wildcard = quality
			} else if strings.EqualFold(name, "identity") {
				identity = quality
			} else {
				explicit = quality
			}
		}
	}
	preference := responseEncodings{gzip: max(explicit, 0), identity: 1, explicitIdentity: identity >= 0}
	if explicit < 0 && wildcard > 0 {
		preference.gzip = wildcard
	}
	if identity >= 0 {
		preference.identity = identity
	} else if wildcard == 0 {
		preference.identity = 0
	}
	return preference
}

func addEncodingVary(header http.Header) {
	for _, value := range header.Values("Vary") {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "Accept-Encoding") || strings.TrimSpace(token) == "*" {
				return
			}
		}
	}
	header.Add("Vary", "Accept-Encoding")
}

type jsonCompressionWriter struct {
	http.ResponseWriter
	status            int
	committed         bool
	disabled          bool
	identityForbidden bool
	gzipRequired      bool
	head              bool
	rejected          bool
	frozenHeader      http.Header
	pending           []byte
	gzip              *gzip.Writer
}

func (w *jsonCompressionWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *jsonCompressionWriter) WriteHeader(status int) {
	if w.committed || w.status != 0 {
		return
	}
	if status < 100 || status > 999 {
		panic("invalid WriteHeader code " + strconv.Itoa(status))
	}
	if status < 200 && status != http.StatusSwitchingProtocols {
		w.ResponseWriter.WriteHeader(status)
		return
	}
	w.status = status
	if status == http.StatusSwitchingProtocols || !w.compressible() {
		if w.identityForbidden && !w.head && status >= 200 && status != http.StatusNoContent && status != http.StatusResetContent && status != http.StatusNotModified && w.Header().Get("Content-Encoding") == "" {
			// This response cannot use either available representation. Keep the
			// negotiation failure empty rather than sending a forbidden coding.
			w.rejected = true
			w.status = http.StatusNotAcceptable
			for _, key := range []string{"Content-Type", "Content-Range", "ETag", "Trailer"} {
				w.Header().Del(key)
			}
			w.Header().Set("Content-Length", "0")
		}
		_ = w.commit(false)
		return
	}
	// Even while the small prefix is buffered, WriteHeader/Write must freeze
	// headers at the same point as net/http. Later handler changes cannot alter
	// the encoding decision or leak into the response headers.
	w.frozenHeader = w.Header().Clone()
}

func (w *jsonCompressionWriter) responseHeader() http.Header {
	if w.frozenHeader != nil {
		return w.frozenHeader
	}
	return w.Header()
}

func (w *jsonCompressionWriter) compressible() bool {
	header := w.responseHeader()
	if w.disabled || w.status < 200 || w.status == http.StatusNoContent || w.status == http.StatusResetContent || w.status == http.StatusNotModified || w.status == http.StatusPartialContent ||
		header.Get("Content-Encoding") != "" || header.Get("Content-Range") != "" || header.Get("ETag") != "" || len(header.Values("Trailer")) != 0 {
		return false
	}
	for _, value := range header.Values("Cache-Control") {
		for _, directive := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(directive), "no-transform") {
				return false
			}
		}
	}
	mediaType, _, _ := strings.Cut(header.Get("Content-Type"), ";")
	return strings.EqualFold(strings.TrimSpace(mediaType), "application/json") ||
		strings.EqualFold(strings.TrimSpace(mediaType), "application/geo+json")
}

func (w *jsonCompressionWriter) commit(compress bool) error {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	// Handlers may replace Vary. Both identity and compressed representations
	// must retain the encoding dimension at the actual header commit.
	addEncodingVary(w.responseHeader())
	if compress {
		w.gzip = jsonGzipWriters.Get().(*gzip.Writer)
		w.gzip.Reset(w.ResponseWriter)
		w.responseHeader().Set("Content-Encoding", "gzip")
		w.responseHeader().Del("Content-Length")
	}
	if w.frozenHeader != nil {
		header := w.Header()
		for key := range header {
			// TrailerPrefix permits trailers announced after the first Write.
			if !strings.HasPrefix(key, http.TrailerPrefix) {
				delete(header, key)
			}
		}
		for key, values := range w.frozenHeader {
			if !strings.HasPrefix(key, http.TrailerPrefix) {
				header[key] = values
			}
		}
		w.frozenHeader = nil
	}
	w.committed = true
	w.ResponseWriter.WriteHeader(w.status)
	if len(w.pending) != 0 {
		_, err := w.output().Write(w.pending)
		w.pending = nil
		return err
	}
	return nil
}

func (w *jsonCompressionWriter) output() io.Writer {
	if w.gzip != nil {
		return w.gzip
	}
	return w.ResponseWriter
}

func (w *jsonCompressionWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.rejected {
		return len(data), nil
	}
	if !w.committed {
		eligible := w.compressible()
		if eligible && !w.gzipRequired && len(w.pending)+len(data) < jsonCompressionMinimum {
			if w.pending == nil {
				w.pending = make([]byte, 0, jsonCompressionMinimum)
			}
			w.pending = append(w.pending, data...)
			return len(data), nil
		}
		if err := w.commit(eligible); err != nil {
			return 0, err
		}
	}
	return w.output().Write(data)
}

// Preserve net/http's optimized file-copy path for identity/binary responses.
// Compressed bodies must still pass through Write and its bounded prefix.
func (w *jsonCompressionWriter) ReadFrom(reader io.Reader) (int64, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.rejected {
		return io.Copy(io.Discard, reader)
	}
	if w.committed && w.gzip == nil {
		if target, ok := w.ResponseWriter.(io.ReaderFrom); ok {
			return target.ReadFrom(reader)
		}
		return io.Copy(w.ResponseWriter, reader)
	}
	return io.Copy(struct{ io.Writer }{w}, reader)
}

// A streaming handler may explicitly flush a small response. Send it directly
// rather than holding it until the threshold is reached. ResponseController can
// reach the underlying writer through Unwrap for other optional capabilities.
func (w *jsonCompressionWriter) FlushError() error {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if !w.committed {
		if err := w.commit(w.gzipRequired && w.compressible()); err != nil {
			return err
		}
	}
	if w.gzip != nil {
		if err := w.gzip.Flush(); err != nil {
			return err
		}
	}
	return http.NewResponseController(w.ResponseWriter).Flush()
}

func (w *jsonCompressionWriter) Flush() { _ = w.FlushError() }

func (w *jsonCompressionWriter) finish() {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if !w.committed {
		_ = w.commit(w.gzipRequired && w.compressible())
	}
	if w.gzip != nil {
		_ = w.gzip.Close()
	}
}

func (w *jsonCompressionWriter) release() {
	if w.gzip != nil {
		// Do not retain the request/connection through a pooled writer.
		w.gzip.Reset(io.Discard)
		jsonGzipWriters.Put(w.gzip)
		w.gzip = nil
	}
}
