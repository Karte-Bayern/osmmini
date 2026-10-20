package mobile

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"slices"
	"sync"
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

// A decoder belongs to one call until expansion finishes. Reusing its flate
// state avoids allocating a 32 KiB history window for every compressed tile.
// Keep the returned bytes separate: callers may decode them after this reader
// is already handling another tile.
type vectorGzipReader struct {
	source bytes.Reader
	reader *gzip.Reader
	ctx    context.Context
	read   int
}

func (r *vectorGzipReader) Read(p []byte) (int, error) {
	if r.ctx != nil {
		if err := r.ctx.Err(); err != nil {
			return 0, err
		}
	}
	return r.source.Read(p)
}

func (r *vectorGzipReader) ReadByte() (byte, error) {
	r.read++
	if r.read&1023 == 0 && r.ctx != nil {
		if err := r.ctx.Err(); err != nil {
			return 0, err
		}
	}
	return r.source.ReadByte()
}

var vectorGzipPool = sync.Pool{New: func() any { return new(vectorGzipReader) }}

func expandVectorGzip(ctx context.Context, data []byte) ([]byte, error) {
	state := vectorGzipPool.Get().(*vectorGzipReader)
	defer func() {
		if state.reader != nil {
			_ = state.reader.Close()
			state.reader.Header = gzip.Header{}
		}
		// The flate reader references source. Clear it before pooling so neither
		// the compressed tile nor optional gzip header strings are retained.
		state.source.Reset(nil)
		state.ctx = nil
		vectorGzipPool.Put(state)
	}()
	state.source.Reset(data)
	state.ctx, state.read = ctx, 0
	var source io.Reader = &state.source
	if ctx != nil {
		source = state
	}
	var err error
	if state.reader == nil {
		state.reader, err = gzip.NewReader(source)
	} else {
		err = state.reader.Reset(source)
	}
	if err != nil {
		return nil, err
	}
	return io.ReadAll(io.LimitReader(state.reader, (16<<20)+1))
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
	ctx   context.Context
}

func (r *fieldReader) next() (field, bool) {
	if len(r.data) == 0 || r.err != nil {
		return field{}, false
	}
	r.count++
	if r.count&1023 == 0 && r.ctx != nil {
		if r.err = r.ctx.Err(); r.err != nil {
			return field{}, false
		}
	}
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
	ctx    context.Context
}

func newValueReader(ctx context.Context, data []byte, count, number int, message []byte) valueReader {
	if count == 1 && data != nil {
		return valueReader{data: data, ctx: ctx}
	}
	if count == 0 {
		return valueReader{}
	}
	return valueReader{fields: fieldReader{data: message, ctx: ctx}, number: number, ctx: ctx}
}

func (r *valueReader) next() (uint64, bool) {
	if r.err != nil {
		return 0, false
	}
	for {
		var value uint64
		if len(r.data) > 0 {
			// Most geometry values are one-byte deltas. Keeping this case in
			// the reader avoids another call and loop for every coordinate.
			v, n := uint64(r.data[0]), 1
			if v >= 0x80 {
				v, n = binary.Uvarint(r.data)
				if n <= 0 {
					r.err = errors.New("invalid packed geometry")
					return 0, false
				}
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
		if r.count&1023 == 0 && r.ctx != nil {
			if r.err = r.ctx.Err(); r.err != nil {
				return 0, false
			}
		}
		if r.count > 500000 {
			r.err = errors.New("vector geometry too large")
			return 0, false
		}
		return value, true
	}
}
func DecodeVectorTile(data []byte) (VectorTile, error) {
	return decodeVectorTile(nil, data)
}

func decodeVectorTile(ctx context.Context, data []byte) (VectorTile, error) {
	out := VectorTile{Features: []VectorFeature{}}
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return out, err
		}
	}
	if len(data) > 16<<20 {
		return out, errors.New("tile exceeds 16 MiB")
	}
	if len(data) > 2 && data[0] == 0x1f && data[1] == 0x8b {
		var err error
		data, err = expandVectorGzip(ctx, data)
		if err != nil {
			return out, err
		}
		if len(data) > 16<<20 {
			return out, errors.New("expanded tile exceeds 16 MiB")
		}
	}
	r := fieldReader{data: data, ctx: ctx}
	for f, ok := r.next(); ok; f, ok = r.next() {
		if f.number == 3 {
			if err := decodeVectorLayer(ctx, f.data, &out); err != nil {
				return out, err
			}
		}
	}
	return out, r.err
}

func decodeVectorLayer(ctx context.Context, data []byte, out *VectorTile) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	name := ""
	extent := uint64(4096)
	var keys, values []string
	featureCount := 0
	r := fieldReader{data: data, ctx: ctx}
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
			v := fieldReader{data: f.data, ctx: ctx}
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
	r = fieldReader{data: data, ctx: ctx}
	for f, ok := r.next(); ok; f, ok = r.next() {
		if f.number != 2 {
			continue
		}
		feature, err := decodeVectorFeature(ctx, f.data, name, int(extent), keys, values)
		if err != nil {
			return err
		}
		out.Features = append(out.Features, feature)
	}
	return r.err
}

func decodeVectorFeature(ctx context.Context, data []byte, layer string, extent int, keys, values []string) (VectorFeature, error) {
	feature := VectorFeature{Layer: layer, Extent: extent}
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return feature, err
		}
	}
	var tags, geom []byte
	tagFields, geomFields := 0, 0
	r := fieldReader{data: data, ctx: ctx}
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
	t := newValueReader(ctx, tags, tagFields, 2, data)
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
	feature.Paths, err = geometry(newValueReader(ctx, geom, geomFields, 4, data))
	return feature, err
}

// A small reusable workspace decodes ordinary road and building features in
// one pass. Final paths receive their own exact allocations; no returned point
// or path aliases the pool. Exceptionally large features keep the exact-size
// two-pass implementation instead of growing the retained workspace.
const vectorGeometryScratchLimit = 4096

type vectorGeometryScratch struct {
	points [][2]int
	ends   []uint16
}

var vectorGeometryPool = sync.Pool{New: func() any { return new(vectorGeometryScratch) }}

func (s *vectorGeometryScratch) appendPoint(point [2]int) bool {
	if len(s.points) == vectorGeometryScratchLimit {
		return false
	}
	if len(s.points) == cap(s.points) {
		capacity := min(max(64, cap(s.points)*2), vectorGeometryScratchLimit)
		points := make([][2]int, len(s.points), capacity)
		copy(points, s.points)
		s.points = points
	}
	s.points = append(s.points, point)
	return true
}

func geometry(commands valueReader) ([][][2]int, error) {
	scratch := vectorGeometryPool.Get().(*vectorGeometryScratch)
	defer func() {
		scratch.points = scratch.points[:0]
		scratch.ends = scratch.ends[:0]
		vectorGeometryPool.Put(scratch)
	}()
	paths, err, complete := scratch.decode(commands)
	if !complete {
		return geometryExact(commands)
	}
	return paths, err
}

func (s *vectorGeometryScratch) decode(commands valueReader) ([][][2]int, error, bool) {
	x, y := int64(0), int64(0)
	start := 0
	for cmd, ok := commands.next(); ok; cmd, ok = commands.next() {
		kind, count := cmd&7, cmd>>3
		if count == 0 || count > 500000 {
			return nil, errors.New("invalid geometry command count"), true
		}
		if kind == 7 {
			if count != 1 || len(s.points) == start {
				return nil, errors.New("invalid close command"), true
			}
			if !s.appendPoint(s.points[start]) {
				return nil, nil, false
			}
			continue
		}
		if kind != 1 && kind != 2 {
			return nil, fmt.Errorf("unsupported geometry command %d", kind), true
		}
		// Leave room for a following ClosePath without parsing a full-sized
		// polygon only to restart it when the closing point is appended.
		if count >= uint64(vectorGeometryScratchLimit-len(s.points)) {
			return nil, nil, false
		}
		for n := uint64(0); n < count; n++ {
			dx, okX := commands.next()
			dy, okY := commands.next()
			if !okX || !okY {
				if commands.err != nil {
					return nil, commands.err, true
				}
				return nil, io.ErrUnexpectedEOF, true
			}
			if kind == 1 && len(s.points) > start {
				s.ends = append(s.ends, uint16(len(s.points)))
				start = len(s.points)
			}
			x += int64(dx>>1) ^ -int64(dx&1)
			y += int64(dy>>1) ^ -int64(dy&1)
			if x < -1<<30 || x > 1<<30 || y < -1<<30 || y > 1<<30 {
				return nil, errors.New("geometry coordinate overflow"), true
			}
			if !s.appendPoint([2]int{int(x), int(y)}) {
				return nil, nil, false
			}
		}
	}
	if commands.err != nil || len(s.points) == 0 {
		return nil, commands.err, true
	}
	s.ends = append(s.ends, uint16(len(s.points)))
	coordinates := make([][2]int, len(s.points))
	copy(coordinates, s.points)
	paths := make([][][2]int, len(s.ends))
	start = 0
	for i, end := range s.ends {
		paths[i] = coordinates[start:end:end]
		start = int(end)
	}
	return paths, nil, true
}

func geometryExact(commands valueReader) ([][][2]int, error) {
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
