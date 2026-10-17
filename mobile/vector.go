package mobile

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"slices"
)

type VectorFeature struct {
	Layer  string     `json:"layer"`
	Kind   int        `json:"kind"`
	Class  string     `json:"class,omitempty"`
	Name   string     `json:"name,omitempty"`
	Extent int        `json:"extent"`
	Paths  [][][2]int `json:"paths"`
}
type VectorTile struct {
	Features []VectorFeature `json:"features"`
}
type field struct {
	number int
	wire   uint64
	value  uint64
	data   []byte
}

// fieldReader retains only the current field. Tile, layer, value and feature
// messages can therefore be traversed without allocating intermediate tables.
type fieldReader struct {
	data  []byte
	count int
	err   error
}

func (r *fieldReader) next() (field, bool) {
	if len(r.data) == 0 || r.err != nil {
		return field{}, false
	}
	r.count++
	if r.count > 500000 {
		r.err = errors.New("vector tile has too many fields")
		return field{}, false
	}
	data := r.data
	tag, n := binary.Uvarint(data)
	if n <= 0 {
		r.err = errors.New("invalid protobuf tag")
		return field{}, false
	}
	data = data[n:]
	f := field{number: int(tag >> 3), wire: tag & 7}
	if tag>>3 == 0 || tag>>3 > (1<<29)-1 {
		r.err = errors.New("invalid protobuf field number")
		return field{}, false
	}
	switch tag & 7 {
	case 0:
		v, n := binary.Uvarint(data)
		if n <= 0 {
			r.err = errors.New("invalid protobuf varint")
			return field{}, false
		}
		f.value = v
		data = data[n:]
	case 1:
		if len(data) < 8 {
			r.err = io.ErrUnexpectedEOF
			return field{}, false
		}
		data = data[8:]
	case 2:
		length, n := binary.Uvarint(data)
		if n <= 0 || length > uint64(len(data)-n) {
			r.err = io.ErrUnexpectedEOF
			return field{}, false
		}
		f.data = data[n : n+int(length)]
		data = data[n+int(length):]
	case 5:
		if len(data) < 4 {
			r.err = io.ErrUnexpectedEOF
			return field{}, false
		}
		data = data[4:]
	default:
		r.err = errors.New("unsupported protobuf field")
		return field{}, false
	}
	r.data = data
	return f, true
}

// valueReader reads packed integers directly from the protobuf payload. The
// usual single packed field takes the fast path; repeated packed or unpacked
// fields are concatenated in wire order, as required by protobuf.
type valueReader struct {
	data   []byte
	fields fieldReader
	number int
	count  int
	err    error
}

func newValueReader(data []byte, count, number int, message []byte) valueReader {
	if count == 1 && data != nil {
		return valueReader{data: data}
	}
	if count == 0 {
		return valueReader{}
	}
	return valueReader{fields: fieldReader{data: message}, number: number}
}

func (r *valueReader) next() (uint64, bool) {
	if r.err != nil {
		return 0, false
	}
	for {
		var value uint64
		if len(r.data) > 0 {
			v, n := binary.Uvarint(r.data)
			if n <= 0 {
				r.err = errors.New("invalid packed geometry")
				return 0, false
			}
			r.data = r.data[n:]
			value = v
		} else {
			f, ok := r.fields.next()
			if !ok {
				r.err = r.fields.err
				return 0, false
			}
			if f.number != r.number {
				continue
			}
			switch f.wire {
			case 2:
				r.data = f.data
				continue
			case 0:
				value = f.value
			default:
				r.err = errors.New("invalid packed field")
				return 0, false
			}
		}
		r.count++
		if r.count > 500000 {
			r.err = errors.New("vector geometry too large")
			return 0, false
		}
		return value, true
	}
}
func DecodeVectorTile(data []byte) (VectorTile, error) {
	out := VectorTile{Features: []VectorFeature{}}
	if len(data) > 16<<20 {
		return out, errors.New("tile exceeds 16 MiB")
	}
	if len(data) > 2 && data[0] == 0x1f && data[1] == 0x8b {
		r, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return out, err
		}
		defer r.Close()
		data, err = io.ReadAll(io.LimitReader(r, (16<<20)+1))
		if err != nil {
			return out, err
		}
		if len(data) > 16<<20 {
			return out, errors.New("expanded tile exceeds 16 MiB")
		}
	}
	r := fieldReader{data: data}
	for f, ok := r.next(); ok; f, ok = r.next() {
		if f.number == 3 {
			if err := decodeVectorLayer(f.data, &out); err != nil {
				return out, err
			}
		}
	}
	return out, r.err
}

func decodeVectorLayer(data []byte, out *VectorTile) error {
	name := ""
	extent := uint64(4096)
	var keys, values []string
	featureCount := 0
	r := fieldReader{data: data}
	for f, ok := r.next(); ok; f, ok = r.next() {
		switch f.number {
		case 1:
			name = string(f.data)
		case 2:
			featureCount++
		case 3:
			keys = append(keys, string(f.data))
		case 4:
			value := ""
			v := fieldReader{data: f.data}
			for f, ok := v.next(); ok; f, ok = v.next() {
				if f.number == 1 {
					value = string(f.data)
				}
			}
			if v.err != nil {
				return v.err
			}
			values = append(values, value)
		case 5:
			extent = f.value
		}
	}
	if r.err != nil {
		return r.err
	}
	if extent == 0 || extent > 1<<24 {
		return errors.New("invalid vector tile extent")
	}
	if featureCount > 50000-len(out.Features) {
		return errors.New("too many vector features")
	}
	out.Features = slices.Grow(out.Features, featureCount)
	// Dictionaries may follow features in the wire message. A second traversal
	// avoids retaining every feature payload while preserving that ordering.
	r = fieldReader{data: data}
	for f, ok := r.next(); ok; f, ok = r.next() {
		if f.number != 2 {
			continue
		}
		feature, err := decodeVectorFeature(f.data, name, int(extent), keys, values)
		if err != nil {
			return err
		}
		out.Features = append(out.Features, feature)
	}
	return r.err
}

func decodeVectorFeature(data []byte, layer string, extent int, keys, values []string) (VectorFeature, error) {
	feature := VectorFeature{Layer: layer, Extent: extent}
	var tags, geom []byte
	tagFields, geomFields := 0, 0
	r := fieldReader{data: data}
	for f, ok := r.next(); ok; f, ok = r.next() {
		switch f.number {
		case 2:
			tags = f.data
			tagFields++
		case 3:
			feature.Kind = int(f.value)
		case 4:
			geom = f.data
			geomFields++
		}
	}
	if r.err != nil {
		return feature, r.err
	}
	t := newValueReader(tags, tagFields, 2, data)
	for key, ok := t.next(); ok; key, ok = t.next() {
		value, ok := t.next()
		if !ok {
			if t.err != nil {
				return feature, t.err
			}
			return feature, errors.New("invalid feature tags")
		}
		if key >= uint64(len(keys)) || value >= uint64(len(values)) {
			return feature, errors.New("invalid tag index")
		}
		switch keys[key] {
		case "class":
			feature.Class = values[value]
		case "name":
			feature.Name = values[value]
		}
	}
	if t.err != nil {
		return feature, t.err
	}
	var err error
	feature.Paths, err = geometry(newValueReader(geom, geomFields, 4, data))
	return feature, err
}

func geometry(commands valueReader) ([][][2]int, error) {
	points, paths, err := geometryPass(commands, nil, nil)
	if err != nil || points == 0 {
		return nil, err
	}
	// One backing allocation holds all points. Cap each individual path at its
	// length so callers can append without overwriting an adjacent path.
	coordinates := make([][2]int, points)
	out := make([][][2]int, paths)
	_, _, err = geometryPass(commands, coordinates, out)
	return out, err
}

// geometryPass first validates and sizes the geometry, then fills those exact
// allocations. It never materializes a separate slice of packed integers.
func geometryPass(commands valueReader, coordinates [][2]int, paths [][][2]int) (int, int, error) {
	x, y := int64(0), int64(0)
	pointCount, pathCount, start := 0, 0, 0
	var first [2]int
	for cmd, ok := commands.next(); ok; cmd, ok = commands.next() {
		kind, count := cmd&7, cmd>>3
		if count == 0 || count > 500000 {
			return 0, 0, errors.New("invalid geometry command count")
		}
		if kind == 7 {
			if count != 1 || pointCount == start {
				return 0, 0, errors.New("invalid close command")
			}
			if coordinates != nil {
				coordinates[pointCount] = first
			}
			pointCount++
			continue
		}
		if kind != 1 && kind != 2 {
			return 0, 0, fmt.Errorf("unsupported geometry command %d", kind)
		}
		for n := uint64(0); n < count; n++ {
			dx, okX := commands.next()
			dy, okY := commands.next()
			if !okX || !okY {
				if commands.err != nil {
					return 0, 0, commands.err
				}
				return 0, 0, io.ErrUnexpectedEOF
			}
			if kind == 1 && pointCount > start {
				if paths != nil {
					paths[pathCount] = coordinates[start:pointCount:pointCount]
				}
				pathCount++
				start = pointCount
			}
			x += int64(dx>>1) ^ -int64(dx&1)
			y += int64(dy>>1) ^ -int64(dy&1)
			if x < -1<<30 || x > 1<<30 || y < -1<<30 || y > 1<<30 {
				return 0, 0, errors.New("geometry coordinate overflow")
			}
			point := [2]int{int(x), int(y)}
			if pointCount == start {
				first = point
			}
			if coordinates != nil {
				coordinates[pointCount] = point
			}
			pointCount++
		}
	}
	if commands.err != nil {
		return 0, 0, commands.err
	}
	if pointCount > start {
		if paths != nil {
			paths[pathCount] = coordinates[start:pointCount:pointCount]
		}
		pathCount++
	}
	return pointCount, pathCount, nil
}
