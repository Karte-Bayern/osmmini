package osmmini

import (
	"bytes"
	"compress/zlib"
	"errors"
	"io"
	"strings"
	"testing"
)

func testPBFZlibBlob(t testing.TB, raw []byte, size int) []byte {
	t.Helper()
	var compressed bytes.Buffer
	writer := zlib.NewWriter(&compressed)
	if _, err := writer.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	blob := testPBFVarintField(2, uint64(size))
	return append(blob, testPBFBytesField(3, compressed.Bytes())...)
}

func TestPBFZlibBlobSizeHintsAndIntegrity(t *testing.T) {
	raw := bytes.Repeat([]byte("OSM primitive block data\x00"), 8000)
	for _, size := range []int{0, -1, len(raw)} {
		decoded, err := parseAndDecompressBlob(testPBFZlibBlob(t, raw, size))
		if err != nil || !bytes.Equal(decoded, raw) {
			t.Fatalf("size hint %d: decoded %d bytes, err=%v", size, len(decoded), err)
		}
	}
	for _, size := range []int{1, len(raw) - 1, len(raw) + 1, 1 << 30} {
		_, err := parseAndDecompressBlob(testPBFZlibBlob(t, raw, size))
		if err == nil || !strings.Contains(err.Error(), "zlib blob size mismatch") {
			t.Fatalf("size hint %d: want size mismatch, got %v", size, err)
		}
	}
	for _, test := range []struct {
		name string
		cut  int
		want error
	}{
		{"checksum", 0, zlib.ErrChecksum},
		{"truncated", 2, io.ErrUnexpectedEOF},
	} {
		t.Run(test.name, func(t *testing.T) {
			var compressed bytes.Buffer
			writer := zlib.NewWriter(&compressed)
			_, _ = writer.Write(raw)
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
			data := compressed.Bytes()
			if test.cut == 0 {
				data[len(data)-1] ^= 1
			} else {
				data = data[:len(data)-test.cut]
			}
			blob := testPBFVarintField(2, uint64(len(raw)))
			blob = append(blob, testPBFBytesField(3, data)...)
			if _, err := parseAndDecompressBlob(blob); !errors.Is(err, test.want) {
				t.Fatalf("want %v, got %v", test.want, err)
			}
		})
	}
}
