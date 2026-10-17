package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type remoteRoundTripper func(*http.Request) (*http.Response, error)

func (f remoteRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func remoteTransport(t testing.TB, rt http.RoundTripper) {
	t.Helper()
	previous := http.DefaultTransport
	http.DefaultTransport = rt
	t.Cleanup(func() { http.DefaultTransport = previous })
}

func BenchmarkRemoteAIRequests(b *testing.B) {
	content := strings.Repeat("route details ", 2500)
	for _, provider := range []string{"ollama", "openai"} {
		b.Run(provider, func(b *testing.B) {
			var response []byte
			if provider == "ollama" {
				response, _ = json.Marshal(map[string]any{"message": map[string]string{"content": content}})
			} else {
				response, _ = json.Marshal(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": content}}}})
			}
			remoteTransport(b, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(response))), ContentLength: int64(len(response)), Request: r}, nil
			}))
			b.ReportAllocs()
			b.SetBytes(int64(len(response)))
			for b.Loop() {
				var got string
				var err error
				if provider == "ollama" {
					got, err = queryOllama(context.Background(), "http://provider.invalid", "test", "system", "user")
				} else {
					got, err = queryOpenAICompatible(context.Background(), "http://provider.invalid", "test", "system", "user", "key")
				}
				if err != nil || got != content {
					b.Fatalf("query = %q, %v", got, err)
				}
			}
		})
	}
}

func TestRemoteBodyBounds(t *testing.T) {
	for _, tc := range []struct {
		name      string
		body      string
		length    int64
		wantError error
	}{
		{"knownExact", "12345678", 8, nil},
		{"unknownExact", "12345678", -1, nil},
		{"knownOversize", "123456789", 9, errRemoteResponseTooLarge},
		{"unknownOversize", "123456789", -1, errRemoteResponseTooLarge},
		{"understatedOversize", "123456789", 3, errRemoteResponseTooLarge},
		{"understatedAccepted", "12345678", 3, nil},
		{"truncated", "123", 8, io.ErrUnexpectedEOF},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := &http.Response{Body: io.NopCloser(strings.NewReader(tc.body)), ContentLength: tc.length}
			body, err := readRemoteBody(resp, 8)
			if !errors.Is(err, tc.wantError) || err == nil && string(body) != tc.body {
				t.Fatalf("body = %q, %v", body, err)
			}
		})
	}
}

func TestRemoteAIRequestAndReply(t *testing.T) {
	for _, provider := range []string{"ollama", "openai"} {
		t.Run(provider, func(t *testing.T) {
			remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
				if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/json" {
					t.Fatalf("request: %s, %v", r.Method, r.Header)
				}
				var request struct {
					Model     string              `json:"model"`
					Messages  []remoteChatMessage `json:"messages"`
					Stream    *bool               `json:"stream"`
					MaxTokens int                 `json:"max_tokens"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Fatal(err)
				}
				if request.Model != "test" || len(request.Messages) != 2 || request.Messages[0] != (remoteChatMessage{"system", "system prompt"}) || request.Messages[1] != (remoteChatMessage{"user", "user prompt"}) {
					t.Fatalf("payload: %+v", request)
				}
				body := `{"message":{"content":"ok"}}`
				if provider == "ollama" {
					if r.URL.Path != "/api/chat" || request.Stream == nil || *request.Stream {
						t.Fatalf("ollama request: %+v", request)
					}
				} else {
					if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer key" || request.MaxTokens != 4096 || request.Stream != nil {
						t.Fatalf("openai request: %+v", request)
					}
					body = `{"choices":[{"message":{"content":"ok"}}]}`
				}
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: r}, nil
			}))
			var got string
			var err error
			if provider == "ollama" {
				got, err = queryOllama(t.Context(), "http://provider.invalid", "test", "system prompt", "user prompt")
			} else {
				got, err = queryOpenAICompatible(t.Context(), "http://provider.invalid", "test", "system prompt", "user prompt", "key")
			}
			if err != nil || got != "ok" {
				t.Fatalf("query = %q, %v", got, err)
			}
		})
	}
}

func TestRemoteAIRejectsOversizedValidJSONPrefix(t *testing.T) {
	for _, known := range []bool{false, true} {
		for _, provider := range []string{"ollama", "openai"} {
			prefix := `{"message":{"content":"ok"}}`
			if provider == "openai" {
				prefix = `{"choices":[{"message":{"content":"ok"}}]}`
			}
			body := prefix + strings.Repeat(" ", maxAIResponseBytes-len(prefix)+1)
			remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
				length := int64(-1)
				if known {
					length = int64(len(body))
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), ContentLength: length, Request: r}, nil
			}))
			var err error
			if provider == "ollama" {
				_, err = queryOllama(t.Context(), "http://provider.invalid", "test", "", "")
			} else {
				_, err = queryOpenAICompatible(t.Context(), "http://provider.invalid", "test", "", "", "")
			}
			if !errors.Is(err, errRemoteResponseTooLarge) {
				t.Fatalf("%s known=%v: %v", provider, known, err)
			}
		}
	}
}

func TestRemoteErrorResponseReusesConnection(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, "temporarily unavailable")
			return
		}
		_, _ = io.WriteString(w, `{"message":{"content":"ok"}}`)
	}))
	t.Cleanup(server.Close)
	if _, err := queryOllama(t.Context(), server.URL, "test", "", ""); err == nil {
		t.Fatal("expected status error")
	}
	reused := false
	ctx := httptrace.WithClientTrace(t.Context(), &httptrace.ClientTrace{GotConn: func(info httptrace.GotConnInfo) { reused = info.Reused }})
	if _, err := queryOllama(ctx, server.URL, "test", "", ""); err != nil {
		t.Fatal(err)
	}
	if !reused {
		t.Fatal("small error body prevented connection reuse")
	}
}

func TestRemoteErrorDrainDoesNotWaitForQueryTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	t.Cleanup(server.Close)
	start := time.Now()
	if _, err := queryOllama(t.Context(), server.URL, "test", "", ""); err == nil {
		t.Fatal("expected status error")
	}
	if time.Since(start) > time.Second {
		t.Fatal("error-body drain stalled")
	}
}

func TestRemoteRequestCancellation(t *testing.T) {
	remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() }))
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := queryOllama(ctx, "http://provider.invalid", "test", "", ""); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
}

func TestRemoteAIPostDoesNotRetryTransientFailures(t *testing.T) {
	for _, provider := range []string{"ollama", "openai"} {
		for _, failure := range []struct {
			name string
			err  error
		}{
			{"transportEOF", io.ErrUnexpectedEOF},
			{"serviceUnavailable", nil},
		} {
			t.Run(provider+"/"+failure.name, func(t *testing.T) {
				var calls atomic.Int32
				remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
					calls.Add(1)
					if r.Method != http.MethodPost || r.Header.Get("Idempotency-Key") != "" || r.Header.Get("X-Idempotency-Key") != "" {
						t.Errorf("AI request must remain an ordinary POST: %s %v", r.Method, r.Header)
					}
					if failure.err != nil {
						return nil, failure.err
					}
					body := `{"error":{"message":"temporarily unavailable"}}`
					return &http.Response{StatusCode: http.StatusServiceUnavailable, Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: r}, nil
				}))
				ctx, cancel := context.WithTimeout(t.Context(), time.Second)
				defer cancel()
				var err error
				if provider == "ollama" {
					_, err = queryOllama(ctx, "http://provider.invalid", "test", "system", "user")
				} else {
					_, err = queryOpenAICompatible(ctx, "http://provider.invalid", "test", "system", "user", "key")
				}
				if err == nil || failure.err != nil && !errors.Is(err, failure.err) {
					t.Fatalf("query error = %v, expected failure %v", err, failure.err)
				}
				if got := calls.Load(); got != 1 {
					t.Fatalf("non-idempotent AI POST sent %d times, want once", got)
				}
			})
		}
	}
}

func TestRemoteModelProbes(t *testing.T) {
	for _, tc := range []struct {
		name          string
		body          string
		wantAvailable bool
		wantModels    []string
	}{
		{"ollama", `{"models":[{"name":"llama"}]}`, true, []string{"llama"}},
		{"compatible", `{"data":[{"id":"local-model"}]}`, true, []string{"local-model"}},
		{"ollamaIgnoresOtherFormat", `{"models":[{"name":"llama"}],"data":"unrelated"}`, true, []string{"llama"}},
		{"compatibleIgnoresOtherFormat", `{"models":"unrelated","data":[{"id":"local-model"}]}`, true, []string{"local-model"}},
		{"invalidJSONStillReachable", `{`, true, nil},
		{"oversized", `{"models":[]}` + strings.Repeat(" ", maxAIResponseBytes), false, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
				if r.URL.Path != "/api/tags" {
					t.Fatalf("path: %s", r.URL.Path)
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(tc.body)), ContentLength: -1, Request: r}, nil
			}))
			got := probeAIProvider(t.Context(), "ollama", "http://provider.invalid", "/api/tags")
			if got.Available != tc.wantAvailable || strings.Join(got.Models, ",") != strings.Join(tc.wantModels, ",") {
				t.Fatalf("probe: %+v", got)
			}
		})
	}
	remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "Bearer key" || r.URL.Path != "/v1/models" {
			t.Fatalf("request: %v", r)
		}
		body := `{"data":[{"id":"chat-model"},{"id":"text-embedding"},{"id":"tts-model"}]}`
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: r}, nil
	}))
	got := probeOpenAI(t.Context(), "openai", "http://provider.invalid", "key")
	if !got.Available || len(got.Models) != 1 || got.Models[0] != "chat-model" {
		t.Fatalf("openai probe: %+v", got)
	}
}

func TestRemoteWikiSummaryBoundsAndCache(t *testing.T) {
	s := &server{wikiCache: make(map[string]string)}
	calls := 0
	body := `{"extract":"summary"}`
	remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != "en.wikipedia.org" {
			t.Fatalf("URL: %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), ContentLength: -1, Request: r}, nil
	}))
	for range 2 {
		if got := s.fetchWikiSummary(t.Context(), "en", "Example"); got != "summary" {
			t.Fatalf("summary: %q", got)
		}
	}
	if calls != 1 {
		t.Fatalf("cache caused %d calls", calls)
	}
	body += strings.Repeat(" ", 8*1024)
	if got := s.fetchWikiSummary(t.Context(), "en", "Oversized"); got != "" {
		t.Fatalf("accepted oversized summary: %q", got)
	}
	if len(s.wikiCache) != 1 {
		t.Fatal("oversized summary cached")
	}
}

func TestRemoteOpenAIErrorMessage(t *testing.T) {
	remoteTransport(t, remoteRoundTripper(func(r *http.Request) (*http.Response, error) {
		body := `{"error":{"message":"model unavailable"}}`
		return &http.Response{StatusCode: 400, Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: r}, nil
	}))
	_, err := queryOpenAICompatible(t.Context(), "http://provider.invalid", "test", "", "", "")
	if err == nil || err.Error() != "API error 400: model unavailable" {
		t.Fatalf("API error: %v", err)
	}
}
