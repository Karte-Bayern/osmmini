package mobile

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"math"
	"os"
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
	b.Helper()
	b.ReportAllocs()
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for b.Loop() {
		tile, err := DecodeVectorTile(data)
		if err != nil || len(tile.Features) == 0 {
			b.Fatalf("decode: %d features, %v", len(tile.Features), err)
		}
	}
}

func BenchmarkDecodeVectorTile(b *testing.B) {
	data := vectorBenchmarkTile()
	b.Run("Viewport", func(b *testing.B) { benchmarkDecodeVectorTile(b, data) })
	b.Run("ViewportGzip", func(b *testing.B) { benchmarkDecodeVectorTile(b, vectorGzip(b, data)) })
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
