package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenUsesValidatedPlaceCatalogAndPreservesLegacyRegions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "region")
	manifest, err := Import(t.Context(), ImportOptions{
		PBF: fixture(t), Destination: path, MinZoom: 14, MaxZoom: 14,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Checksums[placeCatalogFilename] == "" {
		t.Fatal("new import did not checksum the settlement catalog")
	}
	catalogPath := filepath.Join(path, placeCatalogFilename)
	original, err := os.ReadFile(catalogPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []struct {
		name     string
		declared bool
		data     []byte
		wantErr  string
	}{
		{name: "new", declared: true, data: original},
		{name: "legacy without sidecar"},
		{name: "legacy ignores unlisted sidecar", data: []byte("incomplete")},
		{name: "declared file missing", declared: true, wantErr: "places.jsonl"},
		{name: "declared file corrupt", declared: true, data: []byte("incomplete"), wantErr: "checksum mismatch"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			current := manifest
			current.Checksums = maps.Clone(manifest.Checksums)
			if !scenario.declared {
				delete(current.Checksums, placeCatalogFilename)
			}
			data, err := json.Marshal(current)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(path, "manifest.json"), data, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(catalogPath); err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			if scenario.data != nil {
				if err := os.WriteFile(catalogPath, scenario.data, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			engine, err := Open(t.Context(), path)
			if scenario.wantErr != "" {
				if err == nil {
					engine.Close()
					t.Fatal("opened incomplete or corrupt declared catalog")
				}
				if !strings.Contains(err.Error(), scenario.wantErr) {
					t.Fatalf("error = %v, want %q", err, scenario.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer engine.Close()
			results, err := engine.Search(t.Context(), "cafe", 10)
			if err != nil || len(results) != 1 || results[0].Label != "Café Test" {
				t.Fatalf("search changed: %+v, %v", results, err)
			}
			after, err := os.ReadFile(filepath.Join(path, "manifest.json"))
			if err != nil || string(after) != string(data) {
				t.Fatalf("Open modified the portable region: %v", err)
			}
			ctx, cancel := context.WithCancel(t.Context())
			cancel()
			if opened, err := Open(ctx, path); !errors.Is(err, context.Canceled) {
				if opened != nil {
					opened.Close()
				}
				t.Fatalf("cancelled Open = %v", err)
			}
		})
	}
}
