package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegionLandmarksAreVerifiedAndOptionalForOlderImports(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "region")
	manifest, err := Import(t.Context(), ImportOptions{PBF: fixture(t), Destination: destination, MinZoom: 14, MaxZoom: 14}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Checksums[landmarkFilename] == "" {
		t.Fatal("new region did not declare its routing index")
	}
	path := filepath.Join(destination, landmarkFilename)
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(t.Context(), destination); err == nil {
		t.Fatal("missing declared routing index accepted")
	}
	corrupt := append([]byte(nil), original...)
	corrupt[len(corrupt)-1] ^= 1
	if err := os.WriteFile(path, corrupt, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(t.Context(), destination); err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("corrupt declared routing index: %v", err)
	}
	// Even a correctly checksummed index from another graph must be rejected.
	other := filepath.Join(t.TempDir(), "other")
	if _, err := Import(t.Context(), ImportOptions{PBF: fixtureWithStreetName(t, "Other Street"), Destination: other, MinZoom: 14, MaxZoom: 14}, nil); err != nil {
		t.Fatal(err)
	}
	mismatch, err := os.ReadFile(filepath.Join(other, landmarkFilename))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, mismatch, 0600); err != nil {
		t.Fatal(err)
	}
	manifest.Checksums[landmarkFilename], err = fileHash(t.Context(), path)
	if err != nil {
		t.Fatal(err)
	}
	saveManifest := func() {
		data, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(destination, "manifest.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	saveManifest()
	if _, err := Open(t.Context(), destination); err == nil || !strings.Contains(err.Error(), "graph mismatch") {
		t.Fatalf("index from another graph: %v", err)
	}
	// Legacy packages have no declaration. Their normal search/routing remains
	// available without creating or silently modifying any region files.
	delete(manifest.Checksums, landmarkFilename)
	saveManifest()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	engine, err := Open(t.Context(), destination)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	if results, err := engine.Search(t.Context(), "Teststraße", 5); err != nil || len(results) == 0 {
		t.Fatalf("legacy search: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("opening legacy region wrote an index")
	}
}

func TestIndexedRegionDoesNotSkipManifestGraphChecksum(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "region")
	manifest, err := Import(t.Context(), ImportOptions{PBF: fixture(t), Destination: destination, MinZoom: 14, MaxZoom: 14}, nil)
	if err != nil {
		t.Fatal(err)
	}
	good := manifest.Checksums["graph.bin"]
	for _, expected := range []string{strings.Repeat("0", 64), "invalid"} {
		manifest.Checksums["graph.bin"] = expected
		data, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(destination, "manifest.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Open(t.Context(), destination); err == nil || !strings.Contains(err.Error(), "checksum") {
			t.Fatalf("incorrect graph checksum accepted: %v", err)
		}
	}
	manifest.Checksums["graph.bin"] = good
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "manifest.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	engine, err := Open(t.Context(), destination)
	if err != nil {
		t.Fatal(err)
	}
	engine.Close()
}
