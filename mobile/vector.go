package mobile

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
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
	value  uint64
	data   []byte
}

func fields(data []byte) ([]field, error) {
	var out []field
	for len(data) > 0 {
		tag, n := binary.Uvarint(data)
		if n <= 0 {
			return nil, errors.New("invalid protobuf tag")
		}
		data = data[n:]
		f := field{number: int(tag >> 3)}
		switch tag & 7 {
		case 0:
			v, n := binary.Uvarint(data)
			if n <= 0 {
				return nil, errors.New("invalid protobuf varint")
			}
			f.value = v
			data = data[n:]
		case 1:
			if len(data) < 8 {
				return nil, io.ErrUnexpectedEOF
			}
			data = data[8:]
		case 2:
			length, n := binary.Uvarint(data)
			if n <= 0 || length > uint64(len(data)-n) {
				return nil, io.ErrUnexpectedEOF
			}
			f.data = data[n : n+int(length)]
			data = data[n+int(length):]
		case 5:
			if len(data) < 4 {
				return nil, io.ErrUnexpectedEOF
			}
			data = data[4:]
		default:
			return nil, errors.New("unsupported protobuf field")
		}
		out = append(out, f)
		if len(out) > 500000 {
			return nil, errors.New("vector tile has too many fields")
		}
	}
	return out, nil
}
func packed(data []byte) ([]uint64, error) {
	var out []uint64
	for len(data) > 0 {
		v, n := binary.Uvarint(data)
		if n <= 0 {
			return nil, errors.New("invalid packed geometry")
		}
		out = append(out, v)
		data = data[n:]
		if len(out) > 500000 {
			return nil, errors.New("vector geometry too large")
		}
	}
	return out, nil
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
	fs, err := fields(data)
	if err != nil {
		return out, err
	}
	for _, f := range fs {
		if f.number != 3 {
			continue
		}
		layer, err := fields(f.data)
		if err != nil {
			return out, err
		}
		name := ""
		extent := 4096
		var keys, values []string
		var features [][]byte
		for _, v := range layer {
			switch v.number {
			case 1:
				name = string(v.data)
			case 2:
				features = append(features, v.data)
			case 3:
				keys = append(keys, string(v.data))
			case 4:
				vs, e := fields(v.data)
				if e != nil {
					return out, e
				}
				value := ""
				for _, vv := range vs {
					if vv.number == 1 {
						value = string(vv.data)
					}
				}
				values = append(values, value)
			case 5:
				extent = int(v.value)
			}
		}
		if extent <= 0 || extent > 1<<24 {
			return out, errors.New("invalid vector tile extent")
		}
		for _, data := range features {
			fs, e := fields(data)
			if e != nil {
				return out, e
			}
			feature := VectorFeature{Layer: name, Extent: extent}
			var geom []uint64
			for _, f := range fs {
				switch f.number {
				case 2:
					tags, e := packed(f.data)
					if e != nil {
						return out, e
					}
					if len(tags)%2 != 0 {
						return out, errors.New("invalid feature tags")
					}
					for i := 0; i < len(tags); i += 2 {
						if tags[i] >= uint64(len(keys)) || tags[i+1] >= uint64(len(values)) {
							return out, errors.New("invalid tag index")
						}
						switch keys[tags[i]] {
						case "class":
							feature.Class = values[tags[i+1]]
						case "name":
							feature.Name = values[tags[i+1]]
						}
					}
				case 3:
					feature.Kind = int(f.value)
				case 4:
					geom, e = packed(f.data)
					if e != nil {
						return out, e
					}
				}
			}
			feature.Paths, e = geometry(geom)
			if e != nil {
				return out, e
			}
			out.Features = append(out.Features, feature)
			if len(out.Features) > 50000 {
				return out, errors.New("too many vector features")
			}
		}
	}
	return out, nil
}
func geometry(commands []uint64) ([][][2]int, error) {
	var paths [][][2]int
	var path [][2]int
	x, y := int64(0), int64(0)
	for i := 0; i < len(commands); {
		cmd := commands[i]
		i++
		kind, count := cmd&7, cmd>>3
		if count == 0 || count > 500000 {
			return nil, errors.New("invalid geometry command count")
		}
		if kind == 7 {
			if count != 1 || len(path) == 0 {
				return nil, errors.New("invalid close command")
			}
			path = append(path, path[0])
			continue
		}
		if kind != 1 && kind != 2 {
			return nil, fmt.Errorf("unsupported geometry command %d", kind)
		}
		if count > uint64(len(commands)-i)/2 {
			return nil, io.ErrUnexpectedEOF
		}
		for n := uint64(0); n < count; n++ {
			if kind == 1 && len(path) > 0 {
				paths = append(paths, path)
				path = nil
			}
			dx, dy := commands[i], commands[i+1]
			i += 2
			x += int64(dx>>1) ^ -int64(dx&1)
			y += int64(dy>>1) ^ -int64(dy&1)
			if x < -1<<30 || x > 1<<30 || y < -1<<30 || y > 1<<30 {
				return nil, errors.New("geometry coordinate overflow")
			}
			path = append(path, [2]int{int(x), int(y)})
		}
	}
	if len(path) > 0 {
		paths = append(paths, path)
	}
	return paths, nil
}
