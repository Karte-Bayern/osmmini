package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
)

const sampleKML = `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Feuerwehrhaus Musterdorf</name>
      <Point><coordinates>12.5,48.5,0</coordinates></Point>
    </Placemark>
  </Document>
</kml>`

func TestImportVectorToGeoJSONPassesGeoJSONThroughUnchanged(t *testing.T) {
	in := []byte(`{"type":"FeatureCollection","features":[]}`)
	out, err := importVectorToGeoJSON(context.Background(), "geojson", bytes.NewReader(in))
	if err != nil {
		t.Fatalf("importVectorToGeoJSON: %v", err)
	}
	if !bytes.Equal(out, in) {
		t.Fatalf("GeoJSON input was modified: got %s, want %s", out, in)
	}
}

func TestImportVectorToGeoJSONFromKML(t *testing.T) {
	out, err := importVectorToGeoJSON(context.Background(), "kml", strings.NewReader(sampleKML))
	if err != nil {
		t.Fatalf("importVectorToGeoJSON(kml): %v", err)
	}
	var fc struct {
		Type     string `json:"type"`
		Features []struct {
			Geometry struct {
				Type        string    `json:"type"`
				Coordinates []float64 `json:"coordinates"`
			} `json:"geometry"`
		} `json:"features"`
	}
	if err := json.Unmarshal(out, &fc); err != nil {
		t.Fatalf("result is not valid GeoJSON: %v\n%s", err, out)
	}
	if len(fc.Features) != 1 {
		t.Fatalf("got %d features, want 1", len(fc.Features))
	}
	if fc.Features[0].Geometry.Type != "Point" {
		t.Fatalf("geometry type = %q, want Point", fc.Features[0].Geometry.Type)
	}
	if len(fc.Features[0].Geometry.Coordinates) < 2 {
		t.Fatalf("coordinates = %v, want at least [lon,lat]", fc.Features[0].Geometry.Coordinates)
	}
}

func TestImportVectorToGeoJSONFromKMZUnwrapsTheInnerKML(t *testing.T) {
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	w, err := zw.Create("doc.kml")
	if err != nil {
		t.Fatalf("zip.Create: %v", err)
	}
	if _, err := w.Write([]byte(sampleKML)); err != nil {
		t.Fatalf("write kml into zip: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip.Close: %v", err)
	}

	out, err := importVectorToGeoJSON(context.Background(), "kmz", bytes.NewReader(zipBuf.Bytes()))
	if err != nil {
		t.Fatalf("importVectorToGeoJSON(kmz): %v", err)
	}
	if !bytes.Contains(out, []byte("Point")) {
		t.Fatalf("expected a Point geometry in the result, got %s", out)
	}
}

func TestImportVectorToGeoJSONRejectsUnknownFormat(t *testing.T) {
	if _, err := importVectorToGeoJSON(context.Background(), "docx", strings.NewReader("x")); err == nil {
		t.Fatal("expected an error for an unsupported format")
	}
}

func TestExtractKMLFromKMZRejectsAZipWithoutKML(t *testing.T) {
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	w, err := zw.Create("readme.txt")
	if err != nil {
		t.Fatalf("zip.Create: %v", err)
	}
	if _, err := w.Write([]byte("no kml here")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip.Close: %v", err)
	}
	if _, err := extractKMLFromKMZ(bytes.NewReader(zipBuf.Bytes())); err == nil {
		t.Fatal("expected an error for a KMZ with no .kml entry")
	}
}

func TestExtractKMLFromKMZRejectsNonZipInput(t *testing.T) {
	if _, err := extractKMLFromKMZ(strings.NewReader("not a zip file")); err == nil {
		t.Fatal("expected an error for non-zip input")
	}
}

func TestVectorFormatFromFilename(t *testing.T) {
	cases := map[string]string{
		"region.geojson":   "geojson",
		"places.KML":       "kml",
		"tour.kmz":         "kmz",
		"boundary.shp.zip": "zip",
		"no-extension":     "",
	}
	for name, want := range cases {
		if got := vectorFormatFromFilename(name); got != want {
			t.Errorf("vectorFormatFromFilename(%q) = %q, want %q", name, got, want)
		}
	}
}
