package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWebAssetVersionTracksServedContents(t *testing.T) {
	t.Chdir(t.TempDir())
	baseline := webAssetVersion()
	if baseline != webAssetVersion() {
		t.Fatal("asset version must be stable")
	}
	if err := os.MkdirAll("cmd/web", 0755); err != nil {
		t.Fatal(err)
	}
	original, err := embedded.ReadFile("web/style.css")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("cmd", "web", "style.css")
	if err := os.WriteFile(path, original, 0644); err != nil {
		t.Fatal(err)
	}
	if webAssetVersion() != baseline {
		t.Fatal("identical local and embedded contents should share a version")
	}
	if err := os.WriteFile(path, append(original, []byte("\n/* changed */")...), 0644); err != nil {
		t.Fatal(err)
	}
	if webAssetVersion() == baseline {
		t.Fatal("changed CSS must invalidate browser assets")
	}
}
