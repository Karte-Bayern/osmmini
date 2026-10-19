package mobile

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCleanMapImportScratchPreservesCheckpointsAndUnrelatedFiles(t *testing.T) {
	stage := t.TempDir()
	stale := []string{".tinytiles-pbf-123/source.tiles", ".tinysql-artifact-456/database/tinysql.pages", "basemap.ttiles.rollback/database/tinysql.pages"}
	keep := []string{
		"source", "graph.bin", "graph.ready", "search.jsonl", "search.jsonl.idx", "search.ready",
		"basemap.ttiles/database/tinysql.pages", "unrelated/source.tiles", ".other-scratch/data",
		".tinytiles-pbf-/data", ".tinysql-artifact-/data", ".tinytiles-pbf-file", ".tinysql-artifact-file",
	}
	write := func(name string) {
		t.Helper()
		path := filepath.Join(stage, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range append(stale, keep...) {
		write(name)
	}
	if err := cleanMapImportScratch(t.Context(), stage); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".tinytiles-pbf-123", ".tinysql-artifact-456", "basemap.ttiles.rollback"} {
		if _, err := os.Lstat(filepath.Join(stage, name)); !os.IsNotExist(err) {
			t.Errorf("interrupted build %s remains: %v", name, err)
		}
	}
	for _, name := range keep {
		data, err := os.ReadFile(filepath.Join(stage, name))
		if err != nil || string(data) != name {
			t.Errorf("preserved file %s changed: %q, %v", name, data, err)
		}
	}
	if err := cleanMapImportScratch(t.Context(), stage); err != nil {
		t.Fatalf("second cleanup: %v", err)
	}
}

func TestCleanMapImportScratchDoesNotFollowSymbolicLinks(t *testing.T) {
	stage, outside := t.TempDir(), t.TempDir()
	path := filepath.Join(outside, "source.pbf")
	if err := os.WriteFile(path, []byte("preserve source"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".tinytiles-pbf-old", ".tinysql-artifact-old", "basemap.ttiles.rollback"} {
		if err := os.Symlink(outside, filepath.Join(stage, name)); err != nil {
			t.Fatal(err)
		}
	}
	if err := cleanMapImportScratch(t.Context(), stage); err != nil {
		t.Fatal(err)
	}
	if entries, err := os.ReadDir(stage); err != nil || len(entries) != 0 {
		t.Fatalf("stale links remain: %v, %v", entries, err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "preserve source" {
		t.Fatalf("external source changed: %q, %v", data, err)
	}
}

func TestCleanMapImportScratchHonorsCancellation(t *testing.T) {
	stage := t.TempDir()
	scratch := filepath.Join(stage, ".tinytiles-pbf-old")
	if err := os.Mkdir(scratch, 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := cleanMapImportScratch(ctx, stage); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled cleanup: %v", err)
	}
	if _, err := os.Stat(scratch); err != nil {
		t.Fatalf("cancelled cleanup removed scratch: %v", err)
	}
}

func TestImportResumeDiscardsInterruptedMapBuilds(t *testing.T) {
	pbf := fixture(t)
	destination := filepath.Join(t.TempDir(), "region")
	stage := destination + ".pending"
	options := ImportOptions{PBF: pbf, Destination: destination, MinZoom: 14, MaxZoom: 14}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	_, err := Import(ctx, options, func(p Progress) {
		if p.Phase == "building_map" {
			cancel()
		}
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("map-phase cancellation: %v", err)
	}
	checkpoints := make(map[string][]byte)
	for _, name := range []string{"source", "graph.bin", "graph.ready", "search.jsonl", "search.jsonl.idx", "search.ready"} {
		checkpoints[name], err = os.ReadFile(filepath.Join(stage, name))
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{".tinytiles-pbf-old", ".tinysql-artifact-old", "basemap.ttiles.rollback"} {
		path := filepath.Join(stage, name)
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "old-build-data"), []byte("unused map work"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Truncate(filepath.Join(path, "old-build-data"), 8<<20); err != nil {
			t.Fatal(err)
		}
	}
	outside := filepath.Join(t.TempDir(), "source.osm.pbf")
	if err := os.WriteFile(outside, []byte("preserve external source"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(outside), filepath.Join(stage, ".tinytiles-pbf-external")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "unrelated"), []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Import(t.Context(), options, nil); err != nil {
		t.Fatalf("resume map import: %v", err)
	}
	for _, name := range []string{".tinytiles-pbf-old", ".tinytiles-pbf-external", ".tinysql-artifact-old", "basemap.ttiles.rollback"} {
		if _, err := os.Lstat(filepath.Join(destination, name)); !os.IsNotExist(err) {
			t.Errorf("published interrupted build %s: %v", name, err)
		}
	}
	for name, before := range checkpoints {
		after, err := os.ReadFile(filepath.Join(destination, name))
		if err != nil || !bytes.Equal(before, after) {
			t.Errorf("resumed checkpoint %s changed: %v", name, err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(destination, "unrelated")); err != nil || string(data) != "preserve" {
		t.Fatalf("unrelated import data changed: %q, %v", data, err)
	}
	if _, err := os.Stat(pbf); err != nil {
		t.Fatalf("source PBF removed: %v", err)
	}
	if data, err := os.ReadFile(outside); err != nil || string(data) != "preserve external source" {
		t.Fatalf("external source changed: %q, %v", data, err)
	}
	engine, err := Open(t.Context(), destination)
	if err != nil {
		t.Fatalf("cleaned region cannot open: %v", err)
	}
	defer engine.Close()
	results, err := engine.Search(t.Context(), "cafe", 10)
	if err != nil || len(results) != 1 || results[0].Label != "Café Test" {
		t.Fatalf("cleaned region search: %+v, %v", results, err)
	}
}
