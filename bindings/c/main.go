//go:build cgo

// The only cgo in the mobile integration is this small C ABI. The engine and
// its storage remain Go code; no SQLite driver is linked by the Apple build.
package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"simonwaldherr.de/go/osmmini/mobile"
	"sync"
	"time"
	"unsafe"
)

type operation struct {
	mu       sync.Mutex
	cancel   context.CancelFunc
	state    string
	progress mobile.Progress
	result   any
	err      string
	engine   uint64
	claimed  bool
	released bool
	changed  chan struct{}
}

var registry = struct {
	sync.Mutex
	next    uint64
	engines map[uint64]*mobile.Engine
	jobs    map[uint64]*operation
}{engines: map[uint64]*mobile.Engine{}, jobs: map[uint64]*operation{}}

type request struct {
	Action string               `json:"action"`
	Engine uint64               `json:"engine"`
	Path   string               `json:"path"`
	Import mobile.ImportOptions `json:"import"`
	Query  string               `json:"query"`
	Limit  int                  `json:"limit"`
	Route  mobile.RouteRequest  `json:"route"`
	Z      int                  `json:"z"`
	X      int                  `json:"x"`
	Y      int                  `json:"y"`
}

type startResponse struct {
	Operation uint64 `json:"operation,omitempty"`
	Error     string `json:"error,omitempty"`
}

type operationResponse struct {
	State    string          `json:"state"`
	Progress mobile.Progress `json:"progress"`
	Result   any             `json:"result"`
	Error    string          `json:"error"`
}

// Signal every waiter while holding mu. Replacing the channel prevents missed
// wakeups between observing a running job and subscribing to its next change.
func (job *operation) signalLocked() {
	close(job.changed)
	job.changed = make(chan struct{})
}

func (job *operation) setProgress(p mobile.Progress) {
	job.mu.Lock()
	defer job.mu.Unlock()
	if job.progress != p {
		job.progress = p
		job.signalLocked()
	}
}

func response(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"error":"response encoding failed"}`)
	}
	return C.CString(string(b))
}
func decode(s string) (request, error) {
	var r request
	if len(s) > 4<<20 {
		return r, errors.New("request too large")
	}
	err := json.Unmarshal([]byte(s), &r)
	return r, err
}

//export OSMminiABIVersion
func OSMminiABIVersion() C.int32_t { return 1 }

//export OSMminiStart
func OSMminiStart(input *C.char) *C.char {
	r, err := decode(C.GoString(input))
	if err != nil {
		return response(startResponse{Error: err.Error()})
	}
	return response(startResponse{Operation: startOperation(r)})
}

func startOperation(r request) uint64 {
	ctx, cancel := context.WithCancel(context.Background())
	job := &operation{cancel: cancel, state: "running", changed: make(chan struct{})}
	registry.Lock()
	registry.next++
	id := registry.next
	registry.jobs[id] = job
	engine := registry.engines[r.Engine]
	registry.Unlock()
	go func() {
		defer cancel()
		defer func() {
			if v := recover(); v != nil {
				job.mu.Lock()
				job.state = "failed"
				job.err = fmt.Sprintf("native operation failed: %v", v)
				job.signalLocked()
				job.mu.Unlock()
			}
		}()
		var value any
		var err error
		var opened *mobile.Engine
		switch r.Action {
		case "import":
			value, err = mobile.Import(ctx, r.Import, job.setProgress)
		case "open":
			opened, err = mobile.Open(ctx, r.Path)
			if err == nil {
				value = opened.Manifest
			}
		case "search", "route", "tile":
			if engine == nil {
				err = errors.New("engine is closed or unknown")
				break
			}
			switch r.Action {
			case "search":
				value, err = engine.Search(ctx, r.Query, r.Limit)
			case "route":
				value, err = engine.Route(ctx, r.Route)
			case "tile":
				value, err = engine.Tile(ctx, r.Z, r.X, r.Y)
			}
		default:
			err = errors.New("unknown action")
		}
		job.mu.Lock()
		defer job.mu.Unlock()
		defer job.signalLocked()
		if ctx.Err() != nil && err == nil {
			err = ctx.Err()
		}
		if err != nil {
			if opened != nil {
				_ = opened.Close()
			}
			job.state = "failed"
			job.err = err.Error()
			return
		}
		if opened != nil {
			registry.Lock()
			registry.next++
			job.engine = registry.next
			registry.engines[job.engine] = opened
			registry.Unlock()
		}
		job.result = value
		job.state = "complete"
	}()
	return id
}
func lookup(id uint64) *operation { registry.Lock(); defer registry.Unlock(); return registry.jobs[id] }

//export OSMminiPoll
func OSMminiPoll(id C.uint64_t) *C.char {
	return operationJSON(uint64(id), 0)
}

//export OSMminiWait
func OSMminiWait(id C.uint64_t, timeoutMS C.int32_t) *C.char {
	return operationJSON(uint64(id), time.Duration(timeoutMS)*time.Millisecond)
}

func operationJSON(id uint64, timeout time.Duration) *C.char {
	state := waitOperation(id, timeout)
	if state.State == "" {
		return response(startResponse{Error: state.Error})
	}
	return response(state)
}

// waitOperation borrows the job pointer while waiting; Release may remove it
// from the registry but cannot invalidate Go-owned state or its change channel.
// No registry or job mutex is held during the wait or response serialization.
func waitOperation(id uint64, timeout time.Duration) operationResponse {
	job := lookup(id)
	if job == nil {
		return operationResponse{Error: "unknown operation"}
	}
	job.mu.Lock()
	if timeout > 0 && job.state == "running" && !job.released {
		changed := job.changed
		job.mu.Unlock()
		timer := time.NewTimer(min(timeout, 60*time.Second))
		select {
		case <-changed:
		case <-timer.C:
		}
		timer.Stop()
		job.mu.Lock()
	}
	defer job.mu.Unlock()
	if job.released {
		return operationResponse{Error: "unknown operation"}
	}
	return operationResponse{State: job.state, Progress: job.progress, Result: job.result, Error: job.err}
}

//export OSMminiTakeEngine
func OSMminiTakeEngine(id C.uint64_t) C.uint64_t {
	return C.uint64_t(takeEngine(uint64(id)))
}

func takeEngine(id uint64) uint64 {
	job := lookup(id)
	if job == nil {
		return 0
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	if job.state != "complete" || job.claimed || job.released {
		return 0
	}
	job.claimed = true
	return job.engine
}

//export OSMminiCancel
func OSMminiCancel(id C.uint64_t) {
	cancelOperation(uint64(id))
}

func cancelOperation(id uint64) {
	if job := lookup(id); job != nil {
		job.cancel()
	}
}

//export OSMminiRelease
func OSMminiRelease(id C.uint64_t) {
	releaseOperation(uint64(id))
}

func releaseOperation(id uint64) {
	job := lookup(id)
	if job == nil {
		return
	}
	job.mu.Lock()
	if job.released {
		job.mu.Unlock()
		return
	}
	if job.state == "running" {
		job.cancel()
		job.mu.Unlock()
		return
	}
	engine, claimed := job.engine, job.claimed
	job.released = true
	job.signalLocked()
	registry.Lock()
	delete(registry.jobs, id)
	registry.Unlock()
	job.mu.Unlock()
	if engine != 0 && !claimed {
		closeEngine(engine)
	}
}

//export OSMminiClose
func OSMminiClose(id C.uint64_t) {
	closeEngine(uint64(id))
}

func closeEngine(id uint64) {
	registry.Lock()
	engine := registry.engines[id]
	delete(registry.engines, id)
	registry.Unlock()
	if engine != nil {
		_ = engine.Close()
	}
}

//export OSMminiFree
func OSMminiFree(buffer *C.char) { C.free(unsafe.Pointer(buffer)) }
func main()                      {}
