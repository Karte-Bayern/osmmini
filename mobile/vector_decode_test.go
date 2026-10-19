package mobile

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"reflect"
	"sync"
	"testing"
)

func vectorTestTile(feature []byte) []byte {
	// Deliberately put dictionaries and metadata after the feature. Protobuf
	// field ordering must not change the interpretation of feature tags.
	layer := vectorMessage(2, feature)
	layer = append(layer, vectorMessage(1, []byte("transportation"))...)
	for _, key := range []string{"class", "name"} {
		layer = append(layer, vectorMessage(3, []byte(key))...)
	}
	for _, value := range []string{"residential", "Teststraße"} {
		layer = append(layer, vectorMessage(4, vectorMessage(1, []byte(value)))...)
	}
	return vectorMessage(3, layer)
}

func vectorTestFeature(geometry []byte) []byte {
	feature := vectorMessage(2, vectorPacked(0, 0, 1, 1))
	feature = append(feature, vectorVarint(3, 2)...)
	return append(feature, vectorMessage(4, geometry)...)
}

func TestVectorGeometryShapes(t *testing.T) {
	for _, test := range []struct {
		name     string
		commands []uint64
		paths    [][][2]int
	}{
		{"empty", nil, nil},
		{"point", []uint64{9, 6, 9}, [][][2]int{{{3, -5}}}},
		{"multipoint", []uint64{17, 6, 10, 4, 3}, [][][2]int{{{3, 5}}, {{5, 3}}}},
		{"multiline", []uint64{9, 6, 10, 18, 4, 0, 0, 7, 9, 1, 6, 10, 3, 3}, [][][2]int{{{3, 5}, {5, 5}, {5, 1}}, {{4, 4}, {2, 2}}}},
		{"polygonWithHole", []uint64{9, 0, 0, 26, 20, 0, 0, 20, 19, 0, 15, 9, 4, 15, 26, 0, 12, 12, 0, 0, 11, 15}, [][][2]int{
			{{0, 0}, {10, 0}, {10, 10}, {0, 10}, {0, 0}},
			{{2, 2}, {2, 8}, {8, 8}, {8, 2}, {2, 2}},
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := vectorTestTile(vectorTestFeature(vectorPacked(test.commands...)))
			plain, err := DecodeVectorTile(data)
			if err != nil || len(plain.Features) != 1 {
				t.Fatalf("decode: %+v, %v", plain, err)
			}
			feature := plain.Features[0]
			if feature.Layer != "transportation" || feature.Kind != 2 || feature.Class != "residential" || feature.Name != "Teststraße" || feature.Extent != 4096 {
				t.Fatalf("metadata: %+v", feature)
			}
			if !reflect.DeepEqual(feature.Paths, test.paths) {
				t.Fatalf("paths: %v, want %v", feature.Paths, test.paths)
			}
			compressed, err := DecodeVectorTile(vectorGzip(t, data))
			if err != nil || !reflect.DeepEqual(plain, compressed) {
				t.Fatalf("gzip differs: %+v, %v", compressed, err)
			}
			for _, path := range feature.Paths {
				if cap(path) != len(path) {
					t.Fatal("appending to a path could overwrite another path")
				}
			}
		})
	}
}

func TestVectorRepeatedPackedAndUnpackedFields(t *testing.T) {
	want, err := DecodeVectorTile(vectorTestTile(vectorTestFeature(vectorPacked(9, 6, 10, 10, 4, 3))))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name string
		data []byte
	}{
		{"splitPacked", append(append(append(vectorMessage(2, vectorPacked(0)), vectorMessage(4, vectorPacked(9, 6))...), vectorMessage(2, vectorPacked(0, 1, 1))...), vectorMessage(4, vectorPacked(10, 10, 4, 3))...)},
		{"unpacked", func() []byte {
			var data []byte
			for _, tag := range []uint64{0, 0, 1, 1} {
				data = append(data, vectorVarint(2, tag)...)
			}
			for _, command := range []uint64{9, 6, 10, 10, 4, 3} {
				data = append(data, vectorVarint(4, command)...)
			}
			return data
		}()},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := append(test.data, vectorVarint(3, 2)...)
			got, err := DecodeVectorTile(vectorTestTile(data))
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("decode: %+v, %v; want %+v", got, err, want)
			}
		})
	}
}

func TestVectorLastScalarValueWins(t *testing.T) {
	layer := vectorVarint(5, 0)
	layer = append(layer, vectorMessage(2, vectorVarint(3, 1))...)
	layer = append(layer, vectorVarint(5, 8192)...)
	tile, err := DecodeVectorTile(vectorMessage(3, layer))
	if err != nil || len(tile.Features) != 1 || tile.Features[0].Extent != 8192 {
		t.Fatalf("duplicate extent: %+v, %v", tile, err)
	}
}

func TestVectorEmptyTileAndUnknownFields(t *testing.T) {
	unknown := binary.AppendUvarint(vectorVarint(20, 123), 21<<3|1)
	unknown = append(unknown, make([]byte, 8)...)
	unknown = binary.AppendUvarint(unknown, 22<<3|5)
	unknown = append(unknown, make([]byte, 4)...)
	unknown = append(unknown, vectorMessage(23, []byte("ignored"))...)
	for _, data := range [][]byte{nil, unknown} {
		tile, err := DecodeVectorTile(data)
		if err != nil {
			t.Fatal(err)
		}
		got, err := json.Marshal(tile)
		if err != nil || string(got) != `{"features":[]}` {
			t.Fatalf("empty JSON: %s, %v", got, err)
		}
	}
}

func TestVectorRejectsMalformedGeometryAndTags(t *testing.T) {
	for _, test := range []struct {
		name    string
		feature []byte
	}{
		{"zeroCount", vectorTestFeature(vectorPacked(1))},
		{"hugeCount", vectorTestFeature(vectorPacked(500001<<3 | 1))},
		{"missingCoordinate", vectorTestFeature(vectorPacked(9, 0))},
		{"invalidCommand", vectorTestFeature(vectorPacked(11))},
		{"closeEmpty", vectorTestFeature(vectorPacked(15))},
		{"multipleClose", vectorTestFeature(vectorPacked(9, 0, 0, 23))},
		{"coordinateOverflow", vectorTestFeature(vectorPacked(9, 1<<32, 0))},
		{"brokenVarint", vectorTestFeature([]byte{9, 0, 0xff})},
		{"overflowVarint", vectorTestFeature(bytes.Repeat([]byte{0xff}, 10))},
		{"oddTags", vectorMessage(2, vectorPacked(0))},
		{"invalidKeyIndex", vectorMessage(2, vectorPacked(2, 0))},
		{"invalidValueIndex", vectorMessage(2, vectorPacked(0, 2))},
		{"invalidTagsWire", append([]byte{2<<3 | 5}, make([]byte, 4)...)},
		{"invalidGeometryWire", append([]byte{4<<3 | 1}, make([]byte, 8)...)},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeVectorTile(vectorTestTile(test.feature)); err == nil {
				t.Fatal("malformed feature accepted")
			}
		})
	}
}

func TestVectorDecoderBounds(t *testing.T) {
	for _, data := range [][]byte{
		{0, 0}, // reserved protobuf field zero
		{0x80},
		{0x1a, 0xff},
		{0x1b},    // unsupported wire type
		{0x19, 1}, // truncated fixed64
		{0x1d, 1}, // truncated fixed32
		vectorMessage(3, vectorVarint(5, 0)),
		vectorMessage(3, vectorVarint(5, 1<<24+1)),
		bytes.Repeat([]byte{0}, (16<<20)+1),
		vectorGzip(t, bytes.Repeat([]byte{0}, (16<<20)+1)),
		bytes.Repeat(vectorVarint(20, 0), 500001),
		vectorMessage(3, bytes.Repeat(vectorMessage(2, nil), 50001)),
		vectorTestTile(vectorTestFeature(bytes.Repeat(vectorPacked(9, 0, 0), 166667))),
	} {
		if _, err := DecodeVectorTile(data); err == nil {
			t.Fatalf("accepted invalid tile (%d bytes, prefix %x)", len(data), data[:min(len(data), 16)])
		}
	}
}

func TestVectorGzipChecksumAndMultistream(t *testing.T) {
	data := vectorTestTile(vectorTestFeature(vectorPacked(9, 0, 0)))
	compressed := vectorGzip(t, data)
	bad := bytes.Clone(compressed)
	bad[len(bad)-8] ^= 1
	for _, data := range [][]byte{bad, compressed[:len(compressed)-1]} {
		if _, err := DecodeVectorTile(data); err == nil {
			t.Fatal("accepted corrupt gzip")
		}
	}
	// Concatenated gzip members represent one protobuf stream.
	combined := append(bytes.Clone(compressed), vectorGzip(t, data)...)
	tile, err := DecodeVectorTile(combined)
	if err != nil || len(tile.Features) != 2 {
		t.Fatalf("gzip multistream: %+v, %v", tile, err)
	}
}

func TestVectorGzipResetAfterCorruptStreams(t *testing.T) {
	data := vectorTestTile(vectorTestFeature(vectorPacked(9, 6, 10)))
	want, err := DecodeVectorTile(data)
	if err != nil {
		t.Fatal(err)
	}
	var metadata bytes.Buffer
	w := gzip.NewWriter(&metadata)
	w.Name, w.Comment = "named-tile", "optional gzip fields"
	w.Extra = bytes.Repeat([]byte{42}, 4096)
	if _, err = w.Write(data); err != nil {
		t.Fatal(err)
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	compressed := vectorGzip(t, data)
	badChecksum := bytes.Clone(compressed)
	badChecksum[len(badChecksum)-8] ^= 1
	for round := 0; round < 4; round++ {
		for _, corrupt := range [][]byte{{0x1f, 0x8b, 0xff}, compressed[:len(compressed)/2], badChecksum} {
			if _, err = DecodeVectorTile(corrupt); err == nil {
				t.Fatal("accepted corrupt gzip")
			}
			// Failure in a header, body or checksum must not contaminate the
			// next tile's stream, dictionaries or optional header fields.
			for _, valid := range [][]byte{metadata.Bytes(), compressed} {
				got, err := DecodeVectorTile(valid)
				if err != nil || !reflect.DeepEqual(got, want) {
					t.Fatalf("valid gzip after corrupt stream: %+v, %v; want %+v", got, err, want)
				}
			}
			both := append(bytes.Clone(compressed), compressed...)
			got, err := DecodeVectorTile(both)
			if err != nil || len(got.Features) != 2 || !reflect.DeepEqual(got.Features[0], want.Features[0]) || !reflect.DeepEqual(got.Features[1], want.Features[0]) {
				t.Fatalf("gzip members after reuse: %+v, %v", got, err)
			}
		}
	}
}

func TestVectorGzipConcurrentDecodingKeepsResultsIndependent(t *testing.T) {
	var compressed [][]byte
	var want []VectorTile
	for _, point := range [][2]int{{3, 5}, {-120, 87}, {4096, -4096}} {
		data := vectorTestTile(vectorTestFeature(vectorPacked(9, vectorZigzag(point[0]), vectorZigzag(point[1]))))
		tile, err := DecodeVectorTile(data)
		if err != nil {
			t.Fatal(err)
		}
		want = append(want, tile)
		compressed = append(compressed, vectorGzip(t, data))
	}
	var group sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		group.Go(func() {
			for round := 0; round < 30; round++ {
				for i, data := range compressed {
					got, err := DecodeVectorTile(data)
					if err != nil || !reflect.DeepEqual(got, want[i]) {
						t.Errorf("concurrent tile %d: %+v, %v; want %+v", i, got, err, want[i])
						return
					}
				}
			}
		})
	}
	group.Wait()
}

func FuzzDecodeVectorTile(f *testing.F) {
	f.Add(vectorBenchmarkTile())
	f.Add(vectorGzip(f, vectorBenchmarkTile()))
	f.Add(vectorTestTile(vectorTestFeature(vectorPacked(9, 0, 0))))
	f.Add([]byte{0x1a, 0xff})
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<20 {
			t.Skip()
		}
		_, _ = DecodeVectorTile(data)
	})
}

// Keep an overflow-sized length seed independent of host int width.
func TestVectorLengthOverflow(t *testing.T) {
	data := binary.AppendUvarint([]byte{0x1a}, ^uint64(0))
	if _, err := DecodeVectorTile(data); err == nil {
		t.Fatal("accepted overflowing protobuf length")
	}
}
