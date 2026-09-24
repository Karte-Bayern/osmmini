package main

import (
	"archive/zip"
	"bytes"
	"context"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	tinysql "github.com/SimonWaldherr/tinySQL"
	"github.com/SimonWaldherr/tinySQL/exporter"
	"github.com/SimonWaldherr/tinySQL/importer"
)

// importVectorToGeoJSON converts a GeoJSON, KML, KMZ or zipped-Shapefile
// source into standard GeoJSON bytes. GeoJSON passes through unchanged;
// every other format goes through tinySQL's format-specific importer into
// an in-memory table, then back out through tinySQL's GeoJSON exporter --
// so all of them land on the exact same, already-tested
// osmmini.ParseImportedLayer/ParseTerritoriesGeoJSON path that plain
// GeoJSON already uses. Shapefiles must be uploaded as a ZIP containing the
// .shp/.dbf/.shx (and optionally .prj) sidecar files together; a bare .shp
// alone cannot be read without them.
func importVectorToGeoJSON(ctx context.Context, format string, src io.Reader) ([]byte, error) {
	format = strings.ToLower(strings.TrimPrefix(format, "."))
	if format == "geojson" || format == "json" {
		return io.ReadAll(src)
	}

	db := tinysql.NewDB()
	const table = "layer"
	var importErr error
	switch format {
	case "kml":
		_, importErr = importer.ImportKML(ctx, db, "default", table, src, nil)
	case "kmz":
		kml, err := extractKMLFromKMZ(src)
		if err != nil {
			return nil, err
		}
		_, importErr = importer.ImportKML(ctx, db, "default", table, bytes.NewReader(kml), nil)
	case "shp", "shapefile", "zip":
		_, importErr = importer.ImportShapefileZip(ctx, db, "default", table, src, nil)
	default:
		return nil, fmt.Errorf("geodata: unsupported vector format %q (want geojson, kml, kmz or shp)", format)
	}
	if importErr != nil {
		return nil, fmt.Errorf("geodata: import %s: %w", format, importErr)
	}

	stmt, err := tinysql.ParseSQL("SELECT * FROM " + table)
	if err != nil {
		return nil, fmt.Errorf("geodata: internal query: %w", err)
	}
	rs, err := tinysql.Execute(ctx, db, "default", stmt)
	if err != nil {
		return nil, fmt.Errorf("geodata: read imported rows: %w", err)
	}
	if len(rs.Rows) == 0 {
		return nil, fmt.Errorf("geodata: %s contained no features", format)
	}

	var buf bytes.Buffer
	if err := exporter.ExportGeoJSON(&buf, rs, "geometry", exporter.Options{}); err != nil {
		return nil, fmt.Errorf("geodata: convert to GeoJSON: %w", err)
	}
	return buf.Bytes(), nil
}

// vectorFormatFromFilename derives an importVectorToGeoJSON format string
// from a filename's extension, so both the HTTP upload and the CLI can
// default to "auto" and still pick the right importer.
func vectorFormatFromFilename(name string) string {
	return strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
}

// extractKMLFromKMZ unzips a KMZ archive and returns the bytes of its KML
// document. tinySQL's own format auto-detection does not special-case
// .kmz -- an unrecognized extension falls through to content sniffing,
// which would misread the raw zip bytes as CSV -- so osmmini unwraps a KMZ
// itself before handing the inner KML to importer.ImportKML.
func extractKMLFromKMZ(src io.Reader) ([]byte, error) {
	data, err := io.ReadAll(src)
	if err != nil {
		return nil, fmt.Errorf("geodata: read kmz: %w", err)
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("geodata: kmz is not a valid zip: %w", err)
	}
	// Prefer doc.kml (the conventional KMZ entry name); otherwise the first
	// *.kml file found, in archive order.
	var fallback *zip.File
	for _, f := range zr.File {
		if !strings.EqualFold(filepath.Ext(f.Name), ".kml") {
			continue
		}
		if strings.EqualFold(filepath.Base(f.Name), "doc.kml") {
			return readZipFile(f)
		}
		if fallback == nil {
			fallback = f
		}
	}
	if fallback == nil {
		return nil, fmt.Errorf("geodata: kmz contains no .kml entry")
	}
	return readZipFile(fallback)
}

func readZipFile(f *zip.File) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, fmt.Errorf("geodata: open %s in kmz: %w", f.Name, err)
	}
	defer func() { _ = rc.Close() }()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, fmt.Errorf("geodata: read %s in kmz: %w", f.Name, err)
	}
	return data, nil
}
