package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"

	tiles "github.com/SimonWaldherr/tinySQL/tiles"
	xtiff "golang.org/x/image/tiff"
)

// maxGeoTIFFImportBytes bounds a single GeoTIFF upload. Orthophotos can be
// sizeable, but the whole file is decoded into memory (both for pixel
// decoding and for the eager tile pyramid below), so this stays well under
// the MBTiles limit in cmd/geodata_tiles.go.
const maxGeoTIFFImportBytes = 512 << 20

const geoTIFFDefaultMaxZoom = 18
const geoTIFFTileSize = 256

// geoTIFFMaxTiles is a safety cap on the eagerly-generated pyramid (see the
// note on tiles.ImportTiles below for why generation must be eager). At the
// default 256px tile size this is a generous but bounded amount of work for
// the single-department, "one imported raster" scope this feature targets.
const geoTIFFMaxTiles = 20000

// webMercatorOriginShift is half the circumference of the spherical Web
// Mercator projection (radius 6378137m, the sphere every XYZ tile server
// assumes) -- the origin shift needed to move [-origin,+origin] to [0,2*origin].
const webMercatorOriginShift = math.Pi * 6378137.0

var errGeoTIFFUnsupportedCRS = errors.New("geotiff: nur EPSG:3857 oder EPSG:4326 werden unterstützt; bitte vorher reprojizieren, z.B. mit gdalwarp -t_srs EPSG:3857")

// handleGeodataGeoTIFF imports a GeoTIFF into the same single custom-tile
// slot cmd/geodata_tiles.go's MBTiles import uses (see the approved plan:
// "Ersetzt denselben Single-Slot wie MBTiles, letzter Import gewinnt").
func (s *server) handleGeodataGeoTIFF(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !s.requireSettingsAdmin(w, r) {
		return
	}
	maxZoom := geoTIFFDefaultMaxZoom
	if v := r.URL.Query().Get("max_zoom"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 22 {
			writeJSONError(w, http.StatusBadRequest, "?max_zoom must be an integer between 0 and 22")
			return
		}
		maxZoom = n
	}

	body := http.MaxBytesReader(w, r.Body, maxGeoTIFFImportBytes)
	raw, err := io.ReadAll(body)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "read upload: "+err.Error())
		return
	}

	geo, err := parseGeoTIFFGeoreference(raw)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	img, err := xtiff.Decode(bytes.NewReader(raw))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "GeoTIFF-Pixel konnten nicht dekodiert werden: "+err.Error())
		return
	}

	source, err := buildGeoTIFFTileSource(img, geo, maxZoom, int64(len(raw)))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := os.MkdirAll(s.customTilesDir, 0o755); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "create tiles directory: "+err.Error())
		return
	}
	if _, err := tiles.ImportTiles(r.Context(), source, s.customTilesArtifactPath(), &tiles.ImportOptions{
		Schema:          tiles.SchemaFlat,
		ReplaceExisting: true,
		Provenance:      map[string]any{"source": "geotiff", "epsg": geo.EPSG},
	}); err != nil {
		writeJSONError(w, http.StatusBadRequest, "GeoTIFF-Import fehlgeschlagen: "+err.Error())
		return
	}
	s.publishCustomTilesArtifact(w)
}

// --- Minimal GeoTIFF georeferencing (raw IFD tag parsing) ---
//
// golang.org/x/image/tiff decodes pixels but exposes no tag access, so the
// georeferencing tags (which it doesn't know about) are read directly from
// the TIFF container here. Scope is deliberately narrow (see the approved
// plan): only axis-aligned, north-up rasters via ModelPixelScaleTag (33550)
// + ModelTiepointTag (33922), and only EPSG:3857/4326 via GeoKeyDirectoryTag
// (34735) -- no ModelTransformationTag, no GeoDoubleParams/GeoASCIIParams
// indirection.

type geoTIFFGeoreference struct {
	OriginX, OriginY       float64 // model coordinates of raster pixel (0,0), top-left
	PixelSizeX, PixelSizeY float64 // always positive; Y decreases going down the raster
	EPSG                   int
}

type tiffIFDEntry struct {
	tag       uint16
	fieldType uint16
	count     uint32
	valueOff  uint32
}

func tiffOrderAndFirstIFD(data []byte) (binary.ByteOrder, uint32, error) {
	if len(data) < 8 {
		return nil, 0, errors.New("geotiff: file too small to be a TIFF")
	}
	var order binary.ByteOrder
	switch string(data[0:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return nil, 0, errors.New("geotiff: not a TIFF file (bad byte-order marker)")
	}
	if order.Uint16(data[2:4]) != 42 {
		return nil, 0, errors.New("geotiff: not a TIFF file (bad magic number)")
	}
	return order, order.Uint32(data[4:8]), nil
}

func readIFDEntries(data []byte, order binary.ByteOrder, offset uint32) ([]tiffIFDEntry, error) {
	if int64(offset)+2 > int64(len(data)) {
		return nil, errors.New("geotiff: IFD offset out of range")
	}
	n := int(order.Uint16(data[offset : offset+2]))
	entriesStart := int64(offset) + 2
	need := entriesStart + int64(n)*12
	if need > int64(len(data)) {
		return nil, errors.New("geotiff: truncated IFD")
	}
	out := make([]tiffIFDEntry, n)
	for i := 0; i < n; i++ {
		e := data[entriesStart+int64(i)*12 : entriesStart+int64(i)*12+12]
		out[i] = tiffIFDEntry{
			tag:       order.Uint16(e[0:2]),
			fieldType: order.Uint16(e[2:4]),
			count:     order.Uint32(e[4:8]),
			valueOff:  order.Uint32(e[8:12]),
		}
	}
	return out, nil
}

func readDoubles(data []byte, order binary.ByteOrder, e tiffIFDEntry) ([]float64, error) {
	if e.fieldType != 12 {
		return nil, fmt.Errorf("geotiff: tag %d has unexpected type %d, want DOUBLE", e.tag, e.fieldType)
	}
	n := int(e.count)
	byteLen := int64(n) * 8
	off := int64(e.valueOff)
	if off < 0 || off+byteLen > int64(len(data)) {
		return nil, fmt.Errorf("geotiff: tag %d value out of range", e.tag)
	}
	out := make([]float64, n)
	for i := 0; i < n; i++ {
		bits := order.Uint64(data[off+int64(i)*8 : off+int64(i)*8+8])
		out[i] = math.Float64frombits(bits)
	}
	return out, nil
}

func readShorts(data []byte, order binary.ByteOrder, e tiffIFDEntry) ([]uint16, error) {
	if e.fieldType != 3 {
		return nil, fmt.Errorf("geotiff: tag %d has unexpected type %d, want SHORT", e.tag, e.fieldType)
	}
	n := int(e.count)
	byteLen := n * 2
	var raw []byte
	if byteLen <= 4 {
		buf := make([]byte, 4)
		order.PutUint32(buf, e.valueOff)
		raw = buf[:byteLen]
	} else {
		off := int64(e.valueOff)
		if off < 0 || off+int64(byteLen) > int64(len(data)) {
			return nil, fmt.Errorf("geotiff: tag %d value out of range", e.tag)
		}
		raw = data[off : off+int64(byteLen)]
	}
	out := make([]uint16, n)
	for i := 0; i < n; i++ {
		out[i] = order.Uint16(raw[i*2 : i*2+2])
	}
	return out, nil
}

// geoTIFFEPSGFromKeys reads GTModelTypeGeoKey (1024) plus ProjectedCSTypeGeoKey
// (3072) or GeographicTypeGeoKey (2048) from a decoded GeoKeyDirectoryTag.
// Only directly-embedded SHORT values (TIFFTagLocation==0) are handled --
// the only encoding these particular integer-code keys normally use.
func geoTIFFEPSGFromKeys(keys []uint16) (int, error) {
	if len(keys) < 4 {
		return 0, errors.New("geotiff: GeoKeyDirectoryTag fehlt (keine CRS-Information)")
	}
	numKeys := int(keys[3])
	modelType, projectedCS, geographicCS := -1, -1, -1
	for i := 0; i < numKeys; i++ {
		base := 4 + i*4
		if base+3 >= len(keys) {
			break
		}
		keyID, loc, value := keys[base], keys[base+1], keys[base+3]
		if loc != 0 {
			continue
		}
		switch keyID {
		case 1024:
			modelType = int(value)
		case 3072:
			projectedCS = int(value)
		case 2048:
			geographicCS = int(value)
		}
	}
	switch modelType {
	case 1:
		if projectedCS <= 0 {
			return 0, errors.New("geotiff: ProjectedCSTypeGeoKey fehlt")
		}
		return projectedCS, nil
	case 2:
		if geographicCS <= 0 {
			return 0, errors.New("geotiff: GeographicTypeGeoKey fehlt")
		}
		return geographicCS, nil
	default:
		return 0, fmt.Errorf("geotiff: nicht unterstützter GTModelTypeGeoKey %d", modelType)
	}
}

func parseGeoTIFFGeoreference(data []byte) (geoTIFFGeoreference, error) {
	order, ifdOffset, err := tiffOrderAndFirstIFD(data)
	if err != nil {
		return geoTIFFGeoreference{}, err
	}
	entries, err := readIFDEntries(data, order, ifdOffset)
	if err != nil {
		return geoTIFFGeoreference{}, err
	}

	var pixelScale, tiepoint []float64
	var geoKeys []uint16
	for _, e := range entries {
		switch e.tag {
		case 33550:
			if pixelScale, err = readDoubles(data, order, e); err != nil {
				return geoTIFFGeoreference{}, err
			}
		case 33922:
			if tiepoint, err = readDoubles(data, order, e); err != nil {
				return geoTIFFGeoreference{}, err
			}
		case 34735:
			if geoKeys, err = readShorts(data, order, e); err != nil {
				return geoTIFFGeoreference{}, err
			}
		}
	}
	if len(pixelScale) < 2 || len(tiepoint) < 6 {
		return geoTIFFGeoreference{}, errors.New("geotiff: nur achsparallele, north-up GeoTIFFs werden unterstützt (ModelPixelScaleTag/ModelTiepointTag fehlt); ggf. vorher mit gdal_translate konvertieren")
	}
	epsg, err := geoTIFFEPSGFromKeys(geoKeys)
	if err != nil {
		return geoTIFFGeoreference{}, err
	}
	if epsg != 3857 && epsg != 4326 {
		return geoTIFFGeoreference{}, fmt.Errorf("%w (gefunden: EPSG:%d)", errGeoTIFFUnsupportedCRS, epsg)
	}
	return geoTIFFGeoreference{
		OriginX:    tiepoint[3] - tiepoint[0]*pixelScale[0],
		OriginY:    tiepoint[4] + tiepoint[1]*pixelScale[1],
		PixelSizeX: pixelScale[0],
		PixelSizeY: pixelScale[1],
		EPSG:       epsg,
	}, nil
}

// --- Reprojection into a Web Mercator tile pyramid ---

func lonLatToWebMercator(lon, lat float64) (x, y float64) {
	x = lon * webMercatorOriginShift / 180.0
	y = math.Log(math.Tan((90+lat)*math.Pi/360.0)) / (math.Pi / 180.0)
	y = y * webMercatorOriginShift / 180.0
	return
}

func webMercatorToLonLat(x, y float64) (lon, lat float64) {
	lon = x / webMercatorOriginShift * 180.0
	latRad := y / webMercatorOriginShift * 180.0
	lat = 180.0 / math.Pi * (2*math.Atan(math.Exp(latRad*math.Pi/180.0)) - math.Pi/2)
	return
}

// geoTIFFExtentWebMercator returns the raster's bounding box in Web Mercator
// meters, reprojecting from EPSG:4326 if that's the source CRS.
func geoTIFFExtentWebMercator(img image.Image, geo geoTIFFGeoreference) (minX, minY, maxX, maxY float64) {
	b := img.Bounds()
	w, h := float64(b.Dx()), float64(b.Dy())
	corners := [4][2]float64{
		{geo.OriginX, geo.OriginY},
		{geo.OriginX + w*geo.PixelSizeX, geo.OriginY},
		{geo.OriginX, geo.OriginY - h*geo.PixelSizeY},
		{geo.OriginX + w*geo.PixelSizeX, geo.OriginY - h*geo.PixelSizeY},
	}
	minX, minY = math.Inf(1), math.Inf(1)
	maxX, maxY = math.Inf(-1), math.Inf(-1)
	for _, c := range corners {
		x, y := c[0], c[1]
		if geo.EPSG == 4326 {
			x, y = lonLatToWebMercator(c[0], c[1])
		}
		minX, minY = math.Min(minX, x), math.Min(minY, y)
		maxX, maxY = math.Max(maxX, x), math.Max(maxY, y)
	}
	return
}

// geoTIFFSamplePixel maps a Web Mercator point back to a source raster pixel
// (nearest-neighbor) and returns false when the point falls outside it.
func geoTIFFSamplePixel(img image.Image, geo geoTIFFGeoreference, mercX, mercY float64) (color.RGBA, bool) {
	srcX, srcY := mercX, mercY
	if geo.EPSG == 4326 {
		srcX, srcY = webMercatorToLonLat(mercX, mercY)
	}
	col := int(math.Floor((srcX - geo.OriginX) / geo.PixelSizeX))
	row := int(math.Floor((geo.OriginY - srcY) / geo.PixelSizeY))
	b := img.Bounds()
	if col < 0 || row < 0 || col >= b.Dx() || row >= b.Dy() {
		return color.RGBA{}, false
	}
	r, g, bl, a := img.At(b.Min.X+col, b.Min.Y+row).RGBA()
	return color.RGBA{R: uint8(r >> 8), G: uint8(g >> 8), B: uint8(bl >> 8), A: uint8(a >> 8)}, true
}

// geoTIFFTileSource implements tiles.Source with an eagerly generated tile
// set. tiles.ImportTiles requires Info() to declare the exact tile count and
// exact total/max byte sizes, then fails the import if ScanTiles doesn't
// reproduce them precisely -- PNG-encoded size isn't predictable ahead of
// encoding, so tiles are rendered once, cached here, and simply replayed by
// ScanTiles instead of being regenerated (see internal/importer/tile_artifact.go
// in the tinySQL module). This bounds the feature to rasters small enough to
// hold their whole pyramid in memory, an accepted V1 tradeoff (see the
// approved plan's "Bewusst nicht im Umfang").
type geoTIFFTileSource struct {
	cached      []tiles.Tile
	sourceBytes int64
	totalBytes  int64
	maxBytes    int64
	maxZoom     int
}

func (g *geoTIFFTileSource) Info(context.Context) (tiles.SourceInfo, error) {
	return tiles.SourceInfo{
		Name:         "GeoTIFF-Import",
		SourceBytes:  g.sourceBytes,
		TileCount:    int64(len(g.cached)),
		TileBytes:    g.totalBytes,
		MaxTileBytes: g.maxBytes,
		Metadata: map[string]string{
			"format":  "png",
			"name":    "GeoTIFF-Import",
			"minzoom": "0",
			"maxzoom": strconv.Itoa(g.maxZoom),
		},
	}, nil
}

func (g *geoTIFFTileSource) ScanTiles(ctx context.Context, visit func(tiles.Tile) error) error {
	for _, t := range g.cached {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := visit(t); err != nil {
			return err
		}
	}
	return nil
}

// buildGeoTIFFTileSource renders every candidate tile from zoom 0 to maxZoom
// by nearest-neighbor point sampling (256x256 samples per tile). A tile
// whose sampling grid is coarser than a small raster's own extent -- at a
// zoom level well below the raster's native resolution -- can miss it
// entirely between sample points and end up empty; this is only reachable
// with a maxZoom set far coarser than a raster's actual size, not at a
// realistic (near-native) zoom.
func buildGeoTIFFTileSource(img image.Image, geo geoTIFFGeoreference, maxZoom int, sourceBytes int64) (*geoTIFFTileSource, error) {
	minX, minY, maxX, maxY := geoTIFFExtentWebMercator(img, geo)

	type tileCoord struct{ z, x, y int }
	var plan []tileCoord
	for z := 0; z <= maxZoom; z++ {
		n := 1 << uint(z)
		tileM := (2 * webMercatorOriginShift) / float64(n)
		xMin := max(0, min(n-1, int(math.Floor((minX+webMercatorOriginShift)/tileM))))
		xMax := max(0, min(n-1, int(math.Floor((maxX+webMercatorOriginShift)/tileM))))
		yMin := max(0, min(n-1, int(math.Floor((minY+webMercatorOriginShift)/tileM))))
		yMax := max(0, min(n-1, int(math.Floor((maxY+webMercatorOriginShift)/tileM))))
		for x := xMin; x <= xMax; x++ {
			for y := yMin; y <= yMax; y++ {
				plan = append(plan, tileCoord{z, x, y})
				if len(plan) > geoTIFFMaxTiles {
					return nil, fmt.Errorf("geotiff: die Kachelpyramide hätte mehr als %d Kacheln; bitte einen niedrigeren ?max_zoom wählen", geoTIFFMaxTiles)
				}
			}
		}
	}

	out := &geoTIFFTileSource{sourceBytes: sourceBytes, maxZoom: maxZoom}
	for _, p := range plan {
		n := 1 << uint(p.z)
		tileM := (2 * webMercatorOriginShift) / float64(n)
		tileMinX := -webMercatorOriginShift + float64(p.x)*tileM
		tileMinY := -webMercatorOriginShift + float64(p.y)*tileM

		tileImg := image.NewRGBA(image.Rect(0, 0, geoTIFFTileSize, geoTIFFTileSize))
		hasData := false
		for py := 0; py < geoTIFFTileSize; py++ {
			// Row 0 is the tile's north (top) edge, i.e. maximum Y.
			my := tileMinY + tileM*(1-float64(py)/geoTIFFTileSize)
			for px := 0; px < geoTIFFTileSize; px++ {
				mx := tileMinX + tileM*float64(px)/geoTIFFTileSize
				if c, ok := geoTIFFSamplePixel(img, geo, mx, my); ok {
					tileImg.Set(px, py, c)
					hasData = true
				}
			}
		}
		if !hasData {
			continue
		}
		var buf bytes.Buffer
		if err := png.Encode(&buf, tileImg); err != nil {
			return nil, fmt.Errorf("geotiff: Kachel konnte nicht kodiert werden: %w", err)
		}
		data := buf.Bytes()
		out.cached = append(out.cached, tiles.Tile{Key: tiles.Key{Z: p.z, X: p.x, Y: p.y}, Data: data})
		out.totalBytes += int64(len(data))
		if int64(len(data)) > out.maxBytes {
			out.maxBytes = int64(len(data))
		}
	}
	if len(out.cached) == 0 {
		return nil, errors.New("geotiff: keine Kachel überschneidet sich mit der Ausdehnung des Rasters (Georeferenzierung prüfen)")
	}
	return out, nil
}
