package mobile

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegionReaderAcceptsPreviousManifestWithoutReplacingIt(t *testing.T) {
	pbf := fixture(t)
	destination := filepath.Join(t.TempDir(), "region")
	options := ImportOptions{PBF: pbf, Destination: destination, MinZoom: 14, MaxZoom: 14}
	manifest, err := Import(t.Context(), options, nil)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Format != FormatVersion {
		t.Fatalf("new imports use format %d, want %d", manifest.Format, FormatVersion)
	}
	path := filepath.Join(destination, "manifest.json")
	for _, format := range []int{1, 2, 3, FormatVersion} {
		manifest.Format = format
		data, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		engine, err := Open(t.Context(), destination)
		if err != nil {
			t.Fatalf("manifest format %d cannot open: %v", format, err)
		}
		results, err := engine.Search(t.Context(), "cafe", 5)
		engine.Close()
		if err != nil || len(results) != 1 {
			t.Fatalf("manifest format %d cannot search: %+v, %v", format, results, err)
		}
		// Explicit imports to a published destination stay idempotent; creating
		// a compact replacement requires another destination, never overwriting.
		existing, err := Import(t.Context(), options, nil)
		if err != nil || existing.Format != format {
			t.Fatalf("retry changed published format %d: %+v, %v", format, existing, err)
		}
		after, err := os.ReadFile(path)
		if err != nil || string(after) != string(data) {
			t.Fatalf("retry replaced published manifest: %v", err)
		}
	}
	manifest.Format = FormatVersion + 1
	data, _ := json.Marshal(manifest)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(t.Context(), destination); err == nil || !strings.Contains(err.Error(), "unsupported region format") {
		t.Fatalf("unknown manifest version accepted: %v", err)
	}
}

func TestCompactImportDoesNotMixPreviousFormatCheckpoints(t *testing.T) {
	pbf := fixture(t)
	destination := filepath.Join(t.TempDir(), "region")
	stage := destination + ".pending"
	if err := os.Mkdir(stage, 0o700); err != nil {
		t.Fatal(err)
	}
	hash, err := fileHash(t.Context(), pbf)
	if err != nil {
		t.Fatal(err)
	}
	oldSignature := fmt.Sprintf("%s:14:14:1:2", hash)
	for name, contents := range map[string]string{
		"source": oldSignature, "graph.ready": "1", "search.ready": "1", "sentinel": "preserve",
	} {
		if err := os.WriteFile(filepath.Join(stage, name), []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	_, err = Import(t.Context(), ImportOptions{PBF: pbf, Destination: destination, MinZoom: 14, MaxZoom: 14}, nil)
	if err == nil || !strings.Contains(err.Error(), "import version") {
		t.Fatalf("mixed checkpoint versions: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(stage, "source"))
	if err != nil || string(data) != oldSignature {
		t.Fatalf("changed old checkpoint signature: %q, %v", data, err)
	}
	data, err = os.ReadFile(filepath.Join(stage, "sentinel"))
	if err != nil || string(data) != "preserve" {
		t.Fatalf("changed old checkpoint files: %q, %v", data, err)
	}
}
