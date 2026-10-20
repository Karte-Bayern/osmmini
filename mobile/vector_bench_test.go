package mobile

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
	"math"
	"os"
	"strconv"
	"testing"
)

func vectorMessage(number int, data []byte) []byte {
	out := binary.AppendUvarint(nil, uint64(number<<3|2))
	out = binary.AppendUvarint(out, uint64(len(data)))
	return append(out, data...)
}

func vectorVarint(number int, value uint64) []byte {
	out := binary.AppendUvarint(nil, uint64(number<<3))
	return binary.AppendUvarint(out, value)
}

func vectorPacked(values ...uint64) []byte {
	var out []byte
	for _, value := range values {
		out = binary.AppendUvarint(out, value)
	}
	return out
}

func vectorZigzag(value int) uint64 { return uint64(int64(value)<<1) ^ uint64(int64(value)>>63) }

// A street-heavy viewport with buildings: shared layer dictionaries, multi-byte
// initial coordinates, and short deltas, as in tiles built by tinyTiles.
func vectorBenchmarkTile() []byte {
	var tile []byte
	for _, layer := range []struct {
		name     string
		class    string
		count    int
		vertices int
		kind     int
	}{{"transportation", "residential", 200, 64, 2}, {"building", "building", 64, 33, 3}} {
		data := vectorMessage(1, []byte(layer.name))
		data = append(data, vectorMessage(3, []byte("class"))...)
		data = append(data, vectorMessage(3, []byte("name"))...)
		data = append(data, vectorMessage(4, vectorMessage(1, []byte(layer.class)))...)
		data = append(data, vectorMessage(4, vectorMessage(1, []byte("Teststraße")))...)
		data = append(data, vectorVarint(5, 4096)...)
		data = append(data, vectorVarint(15, 2)...)
		for i := 0; i < layer.count; i++ {
			geometry := vectorPacked(9, vectorZigzag(i*11), vectorZigzag(i*7), uint64((layer.vertices-1)<<3|2))
			for n := 1; n < layer.vertices; n++ {
				geometry = append(geometry, vectorPacked(vectorZigzag(n%5-2), vectorZigzag(n%7-3))...)
			}
			if layer.kind == 3 {
				geometry = binary.AppendUvarint(geometry, 15)
			}
			feature := vectorMessage(2, vectorPacked(0, 0, 1, 1))
			feature = append(feature, vectorVarint(3, uint64(layer.kind))...)
			feature = append(feature, vectorMessage(4, geometry)...)
			data = append(data, vectorMessage(2, feature)...)
		}
		tile = append(tile, vectorMessage(3, data)...)
	}
	return tile
}

func vectorGzip(t testing.TB, data []byte) []byte {
	t.Helper()
	var out bytes.Buffer
	w := gzip.NewWriter(&out)
	if _, err := w.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func benchmarkDecodeVectorTile(b *testing.B, data []byte) {
	benchmarkDecodeVectorTileContext(b, data, nil)
}

func benchmarkDecodeVectorTileContext(b *testing.B, data []byte, ctx context.Context) {
	b.Helper()
	b.ReportAllocs()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for b.Loop() {
		tile, err := decodeVectorTile(ctx, data)
		if err != nil || len(tile.Features) == 0 {
			b.Fatalf("decode: %d features, %v", len(tile.Features), err)
		}
	}
}

func BenchmarkDecodeVectorTile(b *testing.B) {
	data := vectorBenchmarkTile()
	b.Run("Viewport", func(b *testing.B) { benchmarkDecodeVectorTile(b, data) })
	b.Run("ViewportGzip", func(b *testing.B) { benchmarkDecodeVectorTile(b, vectorGzip(b, data)) })
	b.Run("ViewportContext", func(b *testing.B) { benchmarkDecodeVectorTileContext(b, data, b.Context()) })
	b.Run("ViewportGzipContext", func(b *testing.B) { benchmarkDecodeVectorTileContext(b, vectorGzip(b, data), b.Context()) })
	for _, vertices := range []int{4096, 4097, 20000} {
		commands := vectorPacked(9, 0, 0, uint64((vertices-1)<<3|2))
		commands = append(commands, bytes.Repeat([]byte{2, 2}, vertices-1)...)
		for _, kind := range []uint64{2, 3} {
			geometry := bytes.Clone(commands)
			if kind == 3 {
				geometry = append(geometry, 15)
			}
			feature := vectorVarint(3, kind)
			feature = append(feature, vectorMessage(4, geometry)...)
			data := vectorMessage(3, vectorMessage(2, feature))
			b.Run("Long/"+strconv.Itoa(vertices)+"/kind"+strconv.Itoa(int(kind)), func(b *testing.B) {
				benchmarkDecodeVectorTile(b, data)
			})
		}
	}
}

// Set OSMMINI_BENCH_REGION to a prepared region to measure an actual tile,
// without making tests depend on a download or local data.
func BenchmarkDecodeVectorTileRegion(b *testing.B) {
	region := os.Getenv("OSMMINI_BENCH_REGION")
	if region == "" {
		b.Skip("set OSMMINI_BENCH_REGION to a prepared offline region")
	}
	e, err := Open(b.Context(), region)
	if err != nil {
		b.Fatal(err)
	}
	defer e.Close()
	z := e.Manifest.MaxZoom
	n := math.Exp2(float64(z))
	lon := (e.Manifest.Bounds.MinLon + e.Manifest.Bounds.MaxLon) / 2
	lat := (e.Manifest.Bounds.MinLat + e.Manifest.Bounds.MaxLat) / 2 * math.Pi / 180
	x := int((lon + 180) / 360 * n)
	y := int((1 - math.Asinh(math.Tan(lat))/math.Pi) / 2 * n)
	data, err := e.tiles.GetTileXYZ(z, x, y)
	if err != nil {
		b.Fatal(err)
	}
	benchmarkDecodeVectorTile(b, data)
}

// Street and building density differs sharply across viewports. Keep actual
// city tiles separate so an improvement cannot hide a regression in one kind
// of geometry behind a single regional average.
func BenchmarkDecodeVectorTileCities(b *testing.B) {
	region := os.Getenv("OSMMINI_BENCH_REGION")
	if region == "" {
		b.Skip("set OSMMINI_BENCH_REGION to a prepared offline region")
	}
	e, err := Open(b.Context(), region)
	if err != nil {
		b.Fatal(err)
	}
	defer e.Close()
	for _, city := range []struct {
		name string
		lat  float64
		lon  float64
	}{
		{"Passau", 48.574, 13.450},
		{"Landshut", 48.538, 12.152},
		{"Deggendorf", 48.832, 12.960},
		{"Straubing", 48.881, 12.574},
	} {
		for _, z := range []int{12, 14} {
			n := math.Exp2(float64(z))
			x := int((city.lon + 180) / 360 * n)
			y := int((1 - math.Asinh(math.Tan(city.lat*math.Pi/180))/math.Pi) / 2 * n)
			data, err := e.tiles.GetTileXYZ(z, x, y)
			if err != nil {
				b.Fatal(err)
			}
			if len(data) > 2 && data[0] == 0x1f && data[1] == 0x8b {
				data, err = expandVectorGzip(nil, data)
				if err != nil {
					b.Fatal(err)
				}
			}
			b.Run(city.name+"/z"+strconv.Itoa(z), func(b *testing.B) {
				b.Run("MVT", func(b *testing.B) { benchmarkDecodeVectorTile(b, data) })
				b.Run("Context", func(b *testing.B) { benchmarkDecodeVectorTileContext(b, data, b.Context()) })
			})
		}
	}
}
