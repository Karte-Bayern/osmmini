//go:build cgo

package main

import (
	"context"
	"encoding/json"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"simonwaldherr.de/go/osmmini/mobile"
)

func testOperation(t *testing.T) (uint64, *operation, context.Context) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	job := &operation{cancel: cancel, state: "running", changed: make(chan struct{})}
	registry.Lock()
	registry.next++
	id := registry.next
	registry.jobs[id] = job
	registry.Unlock()
	t.Cleanup(func() {
		cancel()
		job.mu.Lock()
		if job.state == "running" {
			job.state = "failed"
			job.err = "test cleanup"
			job.signalLocked()
		}
		job.mu.Unlock()
		releaseOperation(id)
	})
	return id, job, ctx
}

func finishTestOperation(job *operation) {
	job.mu.Lock()
	job.state = "complete"
	job.result = "ready"
	job.signalLocked()
	job.mu.Unlock()
}

func terminalOperation(t *testing.T, id uint64) operationResponse {
	t.Helper()
	for {
		state := waitOperation(id, time.Second)
		if state.State != "running" {
			return state
		}
		if t.Context().Err() != nil {
			t.Fatal(t.Context().Err())
		}
	}
}

func TestWaitProgressBroadcastAndSnapshots(t *testing.T) {
	id, job, _ := testOperation(t)
	changed := job.changed
	progress := mobile.Progress{Phase: "graph", Fraction: 0.25}
	job.setProgress(progress)
	select {
	case <-changed:
	default:
		t.Fatal("progress did not notify waiters")
	}
	unchanged := job.changed
	job.setProgress(progress)
	select {
	case <-unchanged:
		t.Fatal("identical progress caused an unnecessary wakeup")
	default:
	}
	state := waitOperation(id, 0)
	if state.State != "running" || state.Progress != progress {
		t.Fatalf("poll snapshot: %+v", state)
	}
	if state := waitOperation(id, time.Millisecond); state.State != "running" {
		t.Fatalf("timeout changed operation state: %+v", state)
	}
	finishTestOperation(job)
	if state := waitOperation(id, time.Hour); state.State != "complete" || state.Result != "ready" {
		t.Fatalf("completed operation did not return its result: %+v", state)
	}
	releaseOperation(id)
	if state := waitOperation(id, time.Hour); state.State != "" || state.Error != "unknown operation" {
		t.Fatalf("released operation remained visible: %+v", state)
	}
}

func TestWaitConcurrentCompletionHasNoLostWakeup(t *testing.T) {
	for range 25 {
		id, job, _ := testOperation(t)
		const waiters = 16
		results := make(chan operationResponse, waiters)
		var ready sync.WaitGroup
		ready.Add(waiters)
		for range waiters {
			go func() {
				ready.Done()
				results <- waitOperation(id, 10*time.Second)
			}()
		}
		ready.Wait()
		finishTestOperation(job)
		for range waiters {
			state := <-results
			if state.State != "complete" || state.Result != "ready" {
				t.Fatalf("completion race returned %+v", state)
			}
		}
		releaseOperation(id)
	}
}

func TestCancelAndReleaseDrainRunningOperation(t *testing.T) {
	id, job, ctx := testOperation(t)
	releaseOperation(id)
	if ctx.Err() != context.Canceled || lookup(id) == nil {
		t.Fatal("release must cancel and retain a running operation for draining")
	}
	cancelOperation(id) // Repeated cancellation is safe.
	job.mu.Lock()
	job.state = "failed"
	job.err = ctx.Err().Error()
	job.signalLocked()
	job.mu.Unlock()
	if state := waitOperation(id, time.Hour); state.State != "failed" || state.Error != context.Canceled.Error() {
		t.Fatalf("cancelled result: %+v", state)
	}
	var group sync.WaitGroup
	for range 16 {
		group.Add(1)
		go func() { defer group.Done(); cancelOperation(id); releaseOperation(id) }()
	}
	group.Wait()
	if lookup(id) != nil || takeEngine(id) != 0 {
		t.Fatal("released operation or engine ownership survived")
	}
}

func TestBridgeEngineOwnershipAndCancellation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "region")
	importID := startOperation(request{Action: "import", Import: mobile.ImportOptions{
		PBF:         filepath.Join("..", "..", "apple", "Tests", "OSMminiTests", "Fixtures", "region.osm.pbf"),
		Destination: path, Name: "Bridge fixture", MinZoom: 14, MaxZoom: 14, TileMemoryBytes: 64 << 20,
	}})
	t.Cleanup(func() { releaseOperation(importID) })
	if state := terminalOperation(t, importID); state.State != "complete" {
		t.Fatalf("import: %+v", state)
	}
	releaseOperation(importID)
	open := func() (uint64, uint64, *mobile.Engine) {
		t.Helper()
		id := startOperation(request{Action: "open", Path: path})
		t.Cleanup(func() { releaseOperation(id) })
		if state := terminalOperation(t, id); state.State != "complete" {
			t.Fatalf("open: %+v", state)
		}
		job := lookup(id)
		job.mu.Lock()
		handle := job.engine
		job.mu.Unlock()
		registry.Lock()
		engine := registry.engines[handle]
		registry.Unlock()
		t.Cleanup(func() { closeEngine(handle) })
		if handle == 0 || engine == nil {
			t.Fatal("successful open did not register an engine")
		}
		return id, handle, engine
	}

	// Releasing an unclaimed open closes its engine, including cancellation
	// racing with an open that already reached its successful terminal state.
	id, handle, engine := open()
	cancelOperation(id)
	releaseOperation(id)
	if _, err := engine.Search(t.Context(), "cafe", 5); err == nil {
		t.Fatal("unclaimed engine was not closed")
	}
	if takeEngine(id) != 0 {
		t.Fatal("released open transferred a closed engine")
	}
	closeEngine(handle)

	// Once claimed, the caller owns the engine independently of the job.
	id, handle, _ = open()
	if takeEngine(id) != handle || takeEngine(id) != 0 {
		t.Fatal("engine ownership did not transfer exactly once")
	}
	releaseOperation(id)
	search := startOperation(request{Action: "search", Engine: handle, Query: "cafe", Limit: 5})
	if state := terminalOperation(t, search); state.State != "complete" {
		t.Fatalf("claimed engine search: %+v", state)
	}
	releaseOperation(search)
	closeEngine(handle)
	closeEngine(handle)
	closed := startOperation(request{Action: "search", Engine: handle, Query: "cafe"})
	if state := terminalOperation(t, closed); state.State != "failed" {
		t.Fatalf("closed handle accepted a request: %+v", state)
	}
	releaseOperation(closed)

	// A claim racing with Release either transfers a live engine or returns
	// zero. It must never return an engine that Release has already closed.
	for range 12 {
		id, handle, engine = open()
		barrier := make(chan struct{})
		claimed := make(chan uint64, 1)
		done := make(chan struct{})
		go func() { <-barrier; claimed <- takeEngine(id) }()
		go func() { <-barrier; releaseOperation(id); close(done) }()
		close(barrier)
		got := <-claimed
		<-done
		_, err := engine.Search(t.Context(), "cafe", 5)
		if got == handle && err != nil {
			t.Fatal("claim returned an engine concurrently closed by Release")
		}
		if got == 0 && err == nil {
			t.Fatal("unclaimed engine survived Release")
		}
		closeEngine(handle)
	}
	// Closing a claimed engine may race with an already queued request. The
	// engine's own lock must keep its mmap alive until that request finishes.
	id, handle, _ = open()
	if takeEngine(id) != handle {
		t.Fatal("could not claim engine for concurrent close")
	}
	releaseOperation(id)
	query := startOperation(request{Action: "search", Engine: handle, Query: "cafe"})
	closeDone := make(chan struct{})
	go func() { closeEngine(handle); close(closeDone) }()
	state := terminalOperation(t, query)
	if state.State != "complete" && state.State != "failed" {
		t.Fatalf("request racing with Close: %+v", state)
	}
	<-closeDone
	releaseOperation(query)

	// Cancel as soon as an asynchronous open is queued. If opening wins the
	// race, releasing its unclaimed handle must still reclaim the engine.
	for range 8 {
		cancelled := startOperation(request{Action: "open", Path: path})
		cancelOperation(cancelled)
		state := terminalOperation(t, cancelled)
		if state.State != "complete" && state.State != "failed" {
			t.Fatalf("cancelled open did not drain: %+v", state)
		}
		job := lookup(cancelled)
		job.mu.Lock()
		opened := job.engine
		job.mu.Unlock()
		releaseOperation(cancelled)
		registry.Lock()
		leaked := registry.engines[opened] != nil
		registry.Unlock()
		if lookup(cancelled) != nil || leaked {
			t.Fatal("cancelled open retained a job or unclaimed engine")
		}
	}
}

func TestOperationFailureAndResponseShape(t *testing.T) {
	id := startOperation(request{Action: "unknown"})
	defer releaseOperation(id)
	state := terminalOperation(t, id)
	if state.State != "failed" || state.Error != "unknown action" {
		t.Fatalf("unknown action: %+v", state)
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	var response map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &response); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"state", "progress", "result", "error"} {
		if _, ok := response[key]; !ok {
			t.Fatalf("missing existing response field %q: %s", key, encoded)
		}
	}
}

func BenchmarkOperationResponseJSON(b *testing.B) {
	state := operationResponse{State: "running", Progress: mobile.Progress{Phase: "graph", Fraction: 0.25}}
	b.Run("typed", func(b *testing.B) {
		b.ReportAllocs()
		for range b.N {
			if _, err := json.Marshal(state); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("previous_map", func(b *testing.B) {
		b.ReportAllocs()
		for range b.N {
			if _, err := json.Marshal(map[string]any{"state": state.State, "progress": state.Progress, "result": state.Result, "error": state.Error}); err != nil {
				b.Fatal(err)
			}
		}
	})
}
