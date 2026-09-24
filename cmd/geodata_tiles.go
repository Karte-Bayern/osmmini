package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	tiles "github.com/SimonWaldherr/tinySQL/tiles"
)

// maxMBTilesImportBytes bounds a single MBTiles upload. Regional raster tile
// sets are routinely hundreds of MB, well above the GeoJSON/KML/shapefile
// limit in cmd/geodata_vector.go.
const maxMBTilesImportBytes = 1 << 30

// customTilesArtifactSubdir is the fixed single slot an MBTiles import is
// published into (see the approved plan: "ein zusätzlicher Slot, wie
// tinyTiles heute", not a multi-source registry). A later import atomically
// replaces this same path (tiles.ImportOptions.ReplaceExisting).
const customTilesArtifactSubdir = "custom"

// customTilesInfo is the public-facing summary of the currently loaded
// custom tile source, derived from standard MBTiles metadata.
type customTilesInfo struct {
	Format      string `json:"format"`
	Name        string `json:"name,omitempty"`
	Attribution string `json:"attribution,omitempty"`
	MinZoom     int    `json:"min_zoom,omitempty"`
	MaxZoom     int    `json:"max_zoom,omitempty"`
	IsVector    bool   `json:"is_vector"`
}

func (s *server) customTilesArtifactPath() string {
	return filepath.Join(s.customTilesDir, customTilesArtifactSubdir)
}

// loadCustomTiles opens an already-imported artifact at startup, if any. A
// missing artifact is harmless: the custom tile source is optional.
func (s *server) loadCustomTiles() {
	path := s.customTilesArtifactPath()
	if _, err := os.Stat(path); err != nil {
		return
	}
	reader, info, err := openCustomTilesArtifact(path)
	if err != nil {
		log.Printf("warning: open custom tiles artifact %s: %v", path, err)
		return
	}
	s.customTilesMu.Lock()
	s.customTiles = reader
	s.customTilesInfo = info
	s.customTilesMu.Unlock()
	log.Printf("Loaded custom tile source: format=%s zoom=%d-%d", info.Format, info.MinZoom, info.MaxZoom)
}

func openCustomTilesArtifact(path string) (tiles.MetadataScanner, customTilesInfo, error) {
	ctx := context.Background()
	reader, err := tiles.OpenArtifact(ctx, path, tiles.OpenOptions{})
	if err != nil {
		return nil, customTilesInfo{}, err
	}
	return reader, customTilesInfoFromReader(ctx, reader), nil
}

func customTilesInfoFromReader(ctx context.Context, reader tiles.MetadataScanner) customTilesInfo {
	info := customTilesInfo{Format: "png"}
	if v, ok, _ := reader.Metadata(ctx, "format"); ok && v != "" {
		info.Format = strings.ToLower(v)
	}
	if v, ok, _ := reader.Metadata(ctx, "name"); ok {
		info.Name = v
	}
	if v, ok, _ := reader.Metadata(ctx, "attribution"); ok {
		info.Attribution = v
	}
	if v, ok, _ := reader.Metadata(ctx, "minzoom"); ok {
		if n, err := strconv.Atoi(v); err == nil {
			info.MinZoom = n
		}
	}
	if v, ok, _ := reader.Metadata(ctx, "maxzoom"); ok {
		if n, err := strconv.Atoi(v); err == nil {
			info.MaxZoom = n
		}
	}
	// Scope V1 (see the approved plan): vector MBTiles (pbf/mvt) import and
	// serve, but without automatic MapLibre style generation -- callers use
	// IsVector to decide whether to offer this as a one-click raster source.
	info.IsVector = info.Format == "pbf" || info.Format == "mvt"
	return info
}

// handleGeodataMBTiles: GET reports the currently loaded custom tile source
// (if any), POST imports a new one (replacing the previous one), DELETE
// removes it. Import/delete require requireSettingsAdmin, matching the
// vector-layer import in cmd/geodata_layers.go (this is imported map data,
// not confidential -- unlike cmd/confidential_objects.go's fail-closed gate).
func (s *server) handleGeodataMBTiles(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.customTilesMu.RLock()
		loaded := s.customTiles != nil
		info := s.customTilesInfo
		s.customTilesMu.RUnlock()
		writeJSON(w, http.StatusOK, map[string]any{"loaded": loaded, "info": info})

	case http.MethodPost:
		if !s.requireSettingsAdmin(w, r) {
			return
		}
		if err := os.MkdirAll(s.customTilesDir, 0o755); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "create tiles directory: "+err.Error())
			return
		}
		// SQLite (the MBTiles container format) needs random file access, so
		// the upload is spooled to disk first -- it cannot be imported
		// directly from the request body stream.
		spool, err := os.CreateTemp(s.customTilesDir, ".mbtiles-upload-*.mbtiles")
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "spool upload: "+err.Error())
			return
		}
		spoolPath := spool.Name()
		defer os.Remove(spoolPath)

		body := http.MaxBytesReader(w, r.Body, maxMBTilesImportBytes)
		_, copyErr := io.Copy(spool, body)
		closeErr := spool.Close()
		if copyErr != nil {
			writeJSONError(w, http.StatusBadRequest, "read upload: "+copyErr.Error())
			return
		}
		if closeErr != nil {
			writeJSONError(w, http.StatusInternalServerError, "spool upload: "+closeErr.Error())
			return
		}

		_, err = tiles.ImportMBTiles(r.Context(), spoolPath, s.customTilesArtifactPath(), &tiles.ImportOptions{
			Schema:          tiles.SchemaAuto,
			ReplaceExisting: true,
		})
		if err != nil {
			if errors.Is(err, tiles.ErrSQLiteImportUnavailable) {
				writeJSONError(w, http.StatusServiceUnavailable, "MBTiles-Import ist in diesem Build nicht verfügbar (fehlender sqliteimport-Build-Tag)")
				return
			}
			writeJSONError(w, http.StatusBadRequest, "MBTiles-Import fehlgeschlagen: "+err.Error())
			return
		}

		s.publishCustomTilesArtifact(w)

	case http.MethodDelete:
		if !s.requireSettingsAdmin(w, r) {
			return
		}
		s.customTilesMu.Lock()
		old := s.customTiles
		s.customTiles = nil
		s.customTilesInfo = customTilesInfo{}
		s.customTilesMu.Unlock()
		if old != nil {
			_ = old.Close()
		}
		_ = os.RemoveAll(s.customTilesArtifactPath())
		w.WriteHeader(http.StatusNoContent)

	default:
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodPost+", "+http.MethodDelete)
		writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// publishCustomTilesArtifact opens the artifact just written to
// s.customTilesArtifactPath() and atomically swaps it into the single
// custom-tiles slot, closing the previous reader only after the swap (its
// still-open file handles remain valid until Close, even though the
// artifact's files on disk were just atomically replaced). Shared by the
// MBTiles import above and the GeoTIFF import in cmd/geodata_geotiff.go,
// which both publish into the same slot.
func (s *server) publishCustomTilesArtifact(w http.ResponseWriter) {
	reader, info, err := openCustomTilesArtifact(s.customTilesArtifactPath())
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "imported artifact could not be opened: "+err.Error())
		return
	}
	s.customTilesMu.Lock()
	old := s.customTiles
	s.customTiles = reader
	s.customTilesInfo = info
	s.customTilesMu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	writeJSON(w, http.StatusOK, info)
}

var geodataTilePathPattern = regexp.MustCompile(`^/api/v1/geodata/tiles/(\d+)/(\d+)/(\d+)(?:\.[a-zA-Z0-9]+)?$`)

var geodataTileFormatContentTypes = map[string]string{
	"png":  "image/png",
	"jpg":  "image/jpeg",
	"jpeg": "image/jpeg",
	"webp": "image/webp",
	"pbf":  "application/x-protobuf",
	"mvt":  "application/x-protobuf",
}

// handleGeodataTile serves one XYZ tile from the imported custom artifact.
// tinySQL/tiles (like MBTiles itself) uses TMS row order (y=0 is the
// southernmost row); browsers request XYZ (y=0 is the northernmost row), so
// the row is flipped before lookup.
func (s *server) handleGeodataTile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	m := geodataTilePathPattern.FindStringSubmatch(r.URL.Path)
	if m == nil {
		writeJSONError(w, http.StatusNotFound, "invalid tile path")
		return
	}
	z, _ := strconv.Atoi(m[1])
	x, _ := strconv.Atoi(m[2])
	xyzY, _ := strconv.Atoi(m[3])

	s.customTilesMu.RLock()
	reader := s.customTiles
	format := s.customTilesInfo.Format
	s.customTilesMu.RUnlock()
	if reader == nil {
		writeJSONError(w, http.StatusNotFound, "no custom tile source imported")
		return
	}

	tmsY := (1 << uint(z)) - 1 - xyzY
	key := tiles.Key{Z: z, X: x, Y: tmsY}
	if err := key.Validate(); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	tile, found, err := reader.Lookup(r.Context(), key)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "tile lookup: "+err.Error())
		return
	}
	if !found {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	contentType := geodataTileFormatContentTypes[format]
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write(tile.Data)
}

// geodataTileURLExt picks the file extension advertised in the dynamic
// tile-source preset's upstream template.
func geodataTileURLExt(format string) string {
	switch format {
	case "jpg", "jpeg":
		return "jpg"
	case "webp":
		return "webp"
	case "pbf", "mvt":
		return "pbf"
	default:
		return "png"
	}
}

// geodataCustomTilePreset returns the dynamic "Eigene Quelle" entry appended
// to GET /api/v1/tile-sources when a raster custom source is loaded, or nil
// otherwise. Vector MBTiles (pbf/mvt) are imported and servable, but are
// deliberately not offered as a one-click raster source -- see the approved
// plan's "Bewusst nicht im Umfang" section (no automatic MapLibre vector
// style generation).
func (s *server) geodataCustomTilePreset() *TileSourcePreset {
	s.customTilesMu.RLock()
	loaded := s.customTiles != nil
	info := s.customTilesInfo
	s.customTilesMu.RUnlock()
	if !loaded || info.IsVector {
		return nil
	}
	label := "Eigene Quelle (Import)"
	if info.Name != "" {
		label = fmt.Sprintf("Eigene Quelle: %s", info.Name)
	}
	attribution := info.Attribution
	if attribution == "" {
		attribution = "Lokal importierte Kartenquelle"
	}
	maxZoom := info.MaxZoom
	if maxZoom <= 0 {
		maxZoom = 19
	}
	return &TileSourcePreset{
		ID:          "geodata_custom",
		Label:       label,
		MapType:     "raster-direct",
		Upstream:    "/api/v1/geodata/tiles/{z}/{x}/{y}." + geodataTileURLExt(info.Format),
		Attribution: attribution,
		MaxZoom:     maxZoom,
	}
}
