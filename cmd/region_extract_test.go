package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseRegionBounds(t *testing.T) {
	bounds, err := parseRegionBounds("11.7,47.8,14.3,49.3")
	if err != nil {
		t.Fatalf("parse bounds: %v", err)
	}
	if got, want := bounds.String(), "11.7,47.8,14.3,49.3"; got != want {
		t.Fatalf("bounds string = %q, want %q", got, want)
	}
	for _, invalid := range []string{"", "11,48,14", "11,48,14,48", "11,48,181,49", "a,48,14,49"} {
		if _, err := parseRegionBounds(invalid); err == nil {
			t.Fatalf("parseRegionBounds(%q) unexpectedly succeeded", invalid)
		}
	}
}

func TestRegionalPBFReuseRequiresMatchingSourceAndBounds(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.osm.pbf")
	output := filepath.Join(dir, "niederbayern.osm.pbf")
	if err := os.WriteFile(source, []byte("source"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(output, []byte("region"), 0o600); err != nil {
		t.Fatal(err)
	}
	bounds := regionBounds{minLon: 11.7, minLat: 47.8, maxLon: 14.3, maxLat: 49.3}
	if err := saveRegionalPBFManifest(source, output, bounds); err != nil {
		t.Fatalf("save manifest: %v", err)
	}
	if !regionalPBFIsReusable(source, output, bounds) {
		t.Fatal("matching regional PBF was not reusable")
	}
	if regionalPBFIsReusable(source, output, regionBounds{minLon: 11.8, minLat: 47.8, maxLon: 14.3, maxLat: 49.3}) {
		t.Fatal("regional PBF was reusable for a different bounding box")
	}
	if err := os.WriteFile(source, []byte("changed source"), 0o600); err != nil {
		t.Fatal(err)
	}
	if regionalPBFIsReusable(source, output, bounds) {
		t.Fatal("regional PBF was reusable after its source changed")
	}
}
