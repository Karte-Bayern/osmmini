package mobile

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"slices"
	"strings"
)

// Settlement labels are derived from the existing search file at opening, so
// previously imported regions gain labels without another PBF import. Only
// settlement labels and exact-name search results remain in memory. The labels
// are grouped into zoom-8 cells; exact matches never scan address/POI records.
type placeLabel struct {
	x, y    float64
	name    string
	kind    string
	minZoom int
}

type placeIndex map[uint32][]placeLabel
type exactPlaceIndex map[string][]SearchResult

type placeCatalog struct {
	labels placeIndex
	exact  exactPlaceIndex
}

const maxExactPlacesPerName = 100 // The public search limit cannot exceed 100.

func placeMinZoom(kind string) int {
	switch kind {
	case "city":
		return 5
	case "town":
		return 8
	case "village":
		return 10
	case "hamlet", "suburb":
		return 12
	case "quarter":
		return 13
	case "neighbourhood", "isolated_dwelling":
		return 14
	}
	return -1
}

func loadPlaces(ctx context.Context, search *searchReader) (placeIndex, error) {
	catalog, err := loadPlaceCatalog(ctx, search)
	if err != nil {
		return nil, err
	}
	return catalog.labels, nil
}

func loadPlaceCatalog(ctx context.Context, search *searchReader) (*placeCatalog, error) {
	index := &placeCatalog{labels: placeIndex{}, exact: exactPlaceIndex{}}
	var data io.Reader = io.NewSectionReader(search.data, 0, search.dataBytes)
	if search.compressedData {
		scratch := searchScratchPool.Get().(*searchScratch)
		defer searchScratchPool.Put(scratch)
		data = &searchDataStream{search: search, ctx: ctx, scratch: scratch}
	}
	reader := bufio.NewReaderSize(data, 64<<10)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		line, err := reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			// Huge address/street records are irrelevant to short map labels.
			// Drain this record in bounded chunks without retaining its text.
			for errors.Is(err, bufio.ErrBufferFull) {
				if err := ctx.Err(); err != nil {
					return nil, err
				}
				_, err = reader.ReadSlice('\n')
			}
		} else if bytes.Contains(line, []byte(`"category"`)) || bytes.Contains(line, []byte(`"place"`)) {
			var record SearchResult
			if decodeErr := json.Unmarshal(line, &record); decodeErr != nil {
				return nil, decodeErr
			}
			kind := record.Place
			if kind == "" {
				kind = record.Category // Regions imported before the place field.
			}
			zoom := placeMinZoom(kind)
			name := strings.TrimSpace(record.Label)
			lat, lon := record.Coordinate.Lat, record.Coordinate.Lon
			if zoom >= 0 && record.Kind != "street" && name != "" && len(name) <= 256 &&
				!math.IsNaN(lat) && !math.IsNaN(lon) && math.Abs(lat) <= 90 && math.Abs(lon) <= 180 {
				lat = max(-85.05112878, min(85.05112878, lat)) * math.Pi / 180
				x := math.Mod((lon+180)/360, 1)
				y := max(0, min(math.Nextafter(1, 0), (1-math.Asinh(math.Tan(lat))/math.Pi)/2))
				key := uint32(int(y*256)*256 + int(x*256))
				index.labels[key] = append(index.labels[key], placeLabel{x: x, y: y, name: name, kind: kind, minZoom: zoom})
				index.exact.add(record)
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return index, nil
			}
			return nil, err
		}
	}
}

// Prefer larger settlements when unrelated places share one exact name. Kind
// and signed OSM ID break ties independently of map iteration or source order.
func compareExactPlaces(a, b SearchResult) int {
	priority := func(result SearchResult) int {
		kind := result.Place
		if kind == "" {
			kind = result.Category
		}
		switch kind {
		case "city":
			return 0
		case "town":
			return 1
		case "village":
			return 2
		case "hamlet":
			return 3
		case "suburb":
			return 4
		case "quarter":
			return 5
		case "neighbourhood":
			return 6
		default: // isolated_dwelling
			return 7
		}
	}
	if difference := priority(a) - priority(b); difference != 0 {
		return difference
	}
	if difference := strings.Compare(a.Kind, b.Kind); difference != 0 {
		return difference
	}
	if a.ID < b.ID {
		return -1
	}
	if a.ID > b.ID {
		return 1
	}
	return 0
}

func (index exactPlaceIndex) add(result SearchResult) {
	key := normalized(result.Label)
	if key == "" {
		return
	}
	result.Text = ""
	matches := index[key]
	for _, existing := range matches {
		if existing.Kind == result.Kind && existing.ID == result.ID {
			return
		}
	}
	position, _ := slices.BinarySearchFunc(matches, result, compareExactPlaces)
	if position >= maxExactPlacesPerName {
		return
	}
	matches = slices.Insert(matches, position, result)
	if len(matches) > maxExactPlacesPerName {
		matches[maxExactPlacesPerName] = SearchResult{}
		matches = matches[:maxExactPlacesPerName]
	}
	index[key] = matches
}

func (index exactPlaceIndex) matches(query string) []SearchResult {
	if index == nil {
		return nil
	}
	query = normalized(query)
	// These whole-query aliases belong to disk search. An unusually named
	// settlement must not intercept an existing category lookup.
	switch query {
	case "apotheke", "tankstelle", "krankenhaus", "supermarkt", "feuerwehr":
		return nil
	}
	return index[query]
}

func (index placeIndex) features(z, x, y int) []VectorFeature {
	if index == nil || z < 5 || z > 22 || x < 0 || y < 0 || x >= 1<<z || y >= 1<<z {
		return nil
	}
	scale := math.Exp2(float64(z))
	x0, y0 := float64(x)/scale, float64(y)/scale
	x1, y1 := float64(x+1)/scale, float64(y+1)/scale
	minX, minY := int(x0*256), int(y0*256)
	maxX, maxY := min(255, int(math.Ceil(x1*256))-1), min(255, int(math.Ceil(y1*256))-1)
	var features []VectorFeature
	for cy := minY; cy <= maxY; cy++ {
		for cx := minX; cx <= maxX; cx++ {
			for _, label := range index[uint32(cy*256+cx)] {
				if z < label.minZoom || label.x < x0 || label.x >= x1 || label.y < y0 || label.y >= y1 {
					continue
				}
				px := min(4095, max(0, int((label.x*scale-float64(x))*4096)))
				py := min(4095, max(0, int((label.y*scale-float64(y))*4096)))
				features = append(features, VectorFeature{
					Layer: "place", Kind: 1, Class: label.kind, Name: label.name, Extent: 4096,
					Paths: [][][2]int{{{px, py}}},
				})
			}
		}
	}
	return features
}
