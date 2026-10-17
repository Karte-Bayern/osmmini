package main

import (
	"errors"
	"io"
	"net/http"
	"time"
)

// Each service keeps its existing timeout. All clients continue to use the
// shared DefaultTransport and its connection pool, including after redirects.
var (
	wikiHTTPClient        = &http.Client{Timeout: 4 * time.Second}
	aiProbeHTTPClient     = &http.Client{Timeout: 3 * time.Second}
	aiQueryHTTPClient     = &http.Client{Timeout: aiQueryTimeout}
	openAIProbeHTTPClient = &http.Client{Timeout: 5 * time.Second}
)

var errRemoteResponseTooLarge = errors.New("remote response exceeds size limit")

// readRemoteBody checks one byte beyond the allowed size. A valid JSON prefix
// followed by excess whitespace must not turn an oversized reply into success.
// Known-length responses use one allocation rather than ReadAll's growth chain.
func readRemoteBody(resp *http.Response, maximum int64) ([]byte, error) {
	if resp.ContentLength > maximum {
		return nil, errRemoteResponseTooLarge
	}
	if resp.ContentLength < 0 {
		body, err := io.ReadAll(io.LimitReader(resp.Body, maximum+1))
		if err != nil {
			return nil, err
		}
		if int64(len(body)) > maximum {
			return nil, errRemoteResponseTooLarge
		}
		return body, nil
	}
	body := make([]byte, resp.ContentLength+1)
	n, err := io.ReadFull(resp.Body, body)
	if int64(n) > maximum {
		return nil, errRemoteResponseTooLarge
	}
	if err == io.EOF || err == io.ErrUnexpectedEOF {
		if int64(n) < resp.ContentLength {
			return nil, io.ErrUnexpectedEOF
		}
		return body[:n], nil
	}
	if err != nil {
		return nil, err
	}
	// A custom transport may understate ContentLength. Keep enforcing the same
	// bound rather than trusting the header or returning a truncated prefix.
	tail, err := io.ReadAll(io.LimitReader(resp.Body, maximum+1-int64(n)))
	if err != nil {
		return nil, err
	}
	if int64(n+len(tail)) > maximum {
		return nil, errRemoteResponseTooLarge
	}
	return append(body[:n], tail...), nil
}

// Drain small error bodies so HTTP/1 connections can be reused. Both bytes and
// time are bounded; a stalled or unbounded error stream must not hold up a call
// for the chat client's full two-minute timeout. Callers still close the body.
func drainRemoteBody(resp *http.Response) {
	const maximum = int64(32 << 10)
	if resp.ContentLength > maximum {
		return
	}
	timer := time.AfterFunc(200*time.Millisecond, func() { _ = resp.Body.Close() })
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maximum+1))
	timer.Stop()
}

type remoteChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func remoteChatMessages(system, user string) [2]remoteChatMessage {
	return [2]remoteChatMessage{{Role: "system", Content: system}, {Role: "user", Content: user}}
}

type remoteOllamaModels struct {
	Models []struct {
		Name string `json:"name"`
	} `json:"models"`
}

type remoteOpenAIModels struct {
	Data []struct {
		ID string `json:"id"`
	} `json:"data"`
}
