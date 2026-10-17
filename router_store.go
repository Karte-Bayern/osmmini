package osmmini

// The mobile graph is an immutable, little-endian adjacency file. Coordinates,
// edges and the spatial grid stay file-backed; the same routing algorithms work
// with both the server's map graph and this representation. No unsafe casts or
// machine-dependent Go serialization form part of the on-disk contract.
import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
)

const graphHeaderSize = 96
const graphNodeSize = 40
const graphEdgeSize = 48
const graphMagic = "OSMMGR01"

type graphMetadata struct {
	Classes []string               `json:"classes"`
	Streets map[string]streetEntry `json:"streets"`
}

type diskGraph struct {
	data                                       []byte
	nodes, edgeCount, edgesOffset, cellsOffset int
	classes                                    []string
	release                                    func() error
}

func (g Graph) coord(id int64) (Coord, bool) {
	if g.store == nil {
		c, ok := g.coords[id]
		return c, ok
	}
	i := g.store.nodeIndex(id)
	if i < 0 {
		return Coord{}, false
	}
	return g.store.coordAt(i), true
}

// nodeRecord and coordAt are for scans that already know the record index.
// Keeping that index avoids looking up each node ID again in the sorted table.
func (d *diskGraph) nodeRecord(i int) []byte {
	return d.data[graphHeaderSize+i*graphNodeSize : graphHeaderSize+(i+1)*graphNodeSize]
}

func (d *diskGraph) coordAt(i int) Coord {
	b := d.nodeRecord(i)
	return Coord{Lat: math.Float64frombits(binary.LittleEndian.Uint64(b[8:])), Lon: math.Float64frombits(binary.LittleEndian.Uint64(b[16:]))}
}

func (d *diskGraph) nodeIndex(id int64) int {
	i := sort.Search(d.nodes, func(i int) bool {
		return int64(binary.LittleEndian.Uint64(d.data[graphHeaderSize+i*graphNodeSize:])) >= id
	})
	if i == d.nodes || int64(binary.LittleEndian.Uint64(d.data[graphHeaderSize+i*graphNodeSize:])) != id {
		return -1
	}
	return i
}

type edgeIterator struct {
	memory  []Edge
	data    []byte
	classes []string
	index   int
}

func (g Graph) edges(id int64) edgeIterator {
	if g.store == nil {
		return edgeIterator{memory: g.adj[id], index: -1}
	}
	d := g.store
	i := d.nodeIndex(id)
	if i < 0 {
		return edgeIterator{index: -1}
	}
	return d.edgesAt(i)
}

func (d *diskGraph) edgesAt(i int) edgeIterator {
	b := d.nodeRecord(i)
	start, count := int(binary.LittleEndian.Uint64(b[24:])), int(binary.LittleEndian.Uint32(b[32:]))
	return edgeIterator{data: d.data[d.edgesOffset+start*graphEdgeSize : d.edgesOffset+(start+count)*graphEdgeSize], classes: d.classes, index: -1}
}
func (i *edgeIterator) next() bool {
	i.index++
	if i.data != nil {
		return i.index < len(i.data)/graphEdgeSize
	}
	return i.index < len(i.memory)
}
func (i *edgeIterator) edge() Edge {
	if i.data == nil {
		return i.memory[i.index]
	}
	b := i.data[i.index*graphEdgeSize:]
	return Edge{To: int64(binary.LittleEndian.Uint64(b)), DistM: math.Float64frombits(binary.LittleEndian.Uint64(b[8:])), SpeedKph: math.Float64frombits(binary.LittleEndian.Uint64(b[16:])), MaxHeightM: math.Float64frombits(binary.LittleEndian.Uint64(b[24:])), MaxWeightT: math.Float64frombits(binary.LittleEndian.Uint64(b[32:])), HwyType: i.classes[binary.LittleEndian.Uint32(b[40:])]}
}
func (g Graph) degree(id int64) int {
	if g.store == nil {
		return len(g.adj[id])
	}
	i := g.store.nodeIndex(id)
	if i < 0 {
		return 0
	}
	return int(binary.LittleEndian.Uint32(g.store.data[graphHeaderSize+i*graphNodeSize+32:]))
}
func (g Graph) eachNode(visit func(int64, Coord)) {
	if g.store == nil {
		for id, c := range g.coords {
			visit(id, c)
		}
		return
	}
	for i := 0; i < g.store.nodes; i++ {
		b := g.store.nodeRecord(i)
		id := int64(binary.LittleEndian.Uint64(b))
		visit(id, g.store.coordAt(i))
	}
}

func (g Graph) eachRoutableNode(visit func(int64, Coord)) {
	if g.store == nil {
		for id, c := range g.coords {
			if len(g.adj[id]) > 0 {
				visit(id, c)
			}
		}
		return
	}
	for i := 0; i < g.store.nodes; i++ {
		b := g.store.nodeRecord(i)
		if binary.LittleEndian.Uint32(b[32:]) > 0 {
			visit(int64(binary.LittleEndian.Uint64(b)), g.store.coordAt(i))
		}
	}
}

// cellNodeIterator is a borrowed view of the spatial index, valid until Close.
// It reads IDs in place rather than allocating a slice for every visited cell.
type cellNodeIterator struct {
	data []byte
	key  int64
	id   int64
}

func (d *diskGraph) cellNodesIter(key int64) cellNodeIterator {
	start := sort.Search(d.nodes, func(i int) bool {
		return int64(binary.LittleEndian.Uint64(d.data[d.cellsOffset+i*16:])) >= key
	})
	return cellNodeIterator{data: d.data[d.cellsOffset+start*16 : d.cellsOffset+d.nodes*16], key: key}
}

func (i *cellNodeIterator) next() bool {
	if len(i.data) < 16 || int64(binary.LittleEndian.Uint64(i.data)) != i.key {
		i.data = nil
		return false
	}
	i.id = int64(binary.LittleEndian.Uint64(i.data[8:]))
	i.data = i.data[16:]
	return true
}

func (i cellNodeIterator) nodeID() int64 {
	return i.id
}

func (d *diskGraph) export() (map[int64]Coord, map[int64][]Edge) {
	coords := make(map[int64]Coord, d.nodes)
	adj := make(map[int64][]Edge, d.nodes)
	// One edge allocation replaces repeated growth of every node's adjacency
	// slice. Full slice expressions keep append on one node from overwriting
	// a neighbouring node's edges in the shared backing array.
	edges := make([]Edge, d.edgeCount)
	for i := 0; i < d.nodes; i++ {
		b := d.nodeRecord(i)
		id := int64(binary.LittleEndian.Uint64(b))
		coords[id] = d.coordAt(i)
		start, count := int(binary.LittleEndian.Uint64(b[24:])), int(binary.LittleEndian.Uint32(b[32:]))
		if count > 0 {
			nodeEdges := edges[start : start+count : start+count]
			it := d.edgesAt(i)
			for j := range nodeEdges {
				it.next()
				nodeEdges[j] = it.edge()
			}
			adj[id] = nodeEdges
		}
	}
	return coords, adj
}

// WriteGraph writes a portable graph snapshot, including street names. The
// caller publishes the containing region atomically once all files are ready.
func (r *Router) WriteGraph(ctx context.Context, path string) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	if r.g.store != nil {
		// A file-backed graph is immutable and already has the portable format.
		// Copy it in bounded chunks instead of sorting all IDs, decoding every
		// edge and rebuilding its spatial index merely to serialize it again.
		return writeGraphSnapshot(ctx, path, r.g.store.data)
	}
	ids := make([]int64, 0, r.NodeCount())
	r.g.eachNode(func(id int64, _ Coord) { ids = append(ids, id) })
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	classes := []string{}
	classIDs := map[string]uint32{}
	for i, id := range ids {
		if i%4096 == 0 {
			if err := ctx.Err(); err != nil {
				return err
			}
		}
		for it := r.g.edges(id); it.next(); {
			e := it.edge()
			if _, ok := r.g.coord(e.To); !ok {
				return fmt.Errorf("graph edge references missing node %d", e.To)
			}
			if _, ok := classIDs[e.HwyType]; !ok {
				classIDs[e.HwyType] = uint32(len(classes))
				classes = append(classes, e.HwyType)
			}
		}
	}
	meta, err := json.Marshal(graphMetadata{classes, r.streets})
	if err != nil {
		return err
	}
	if len(meta) > 64<<20 {
		return errors.New("graph street metadata exceeds format limit; split the region")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer func() {
		closeErr := f.Close()
		if err == nil {
			err = closeErr
		}
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	w := bufio.NewWriterSize(f, 1<<20)
	var header [graphHeaderSize]byte
	copy(header[:], graphMagic)
	put := binary.LittleEndian.PutUint64
	put(header[8:], uint64(len(ids)))
	put(header[16:], uint64(r.EdgeCount()))
	put(header[24:], uint64(len(meta)))
	bounds, _ := r.Bounds()
	for i, v := range []float64{bounds.MinLat, bounds.MaxLat, bounds.MinLon, bounds.MaxLon} {
		put(header[32+i*8:], math.Float64bits(v))
	}
	if _, err = w.Write(header[:]); err != nil {
		return err
	}
	var record [graphEdgeSize]byte
	var edgeStart uint64
	for n, id := range ids {
		if n%4096 == 0 {
			if err = ctx.Err(); err != nil {
				return err
			}
		}
		clear(record[:])
		c, _ := r.g.coord(id)
		put(record[:], uint64(id))
		put(record[8:], math.Float64bits(c.Lat))
		put(record[16:], math.Float64bits(c.Lon))
		put(record[24:], edgeStart)
		degree := r.g.degree(id)
		binary.LittleEndian.PutUint32(record[32:], uint32(degree))
		edgeStart += uint64(degree)
		if _, err = w.Write(record[:graphNodeSize]); err != nil {
			return err
		}
	}
	for n, id := range ids {
		if n%4096 == 0 {
			if err = ctx.Err(); err != nil {
				return err
			}
		}
		for it := r.g.edges(id); it.next(); {
			e := it.edge()
			clear(record[:])
			put(record[:], uint64(e.To))
			for i, v := range []float64{e.DistM, e.SpeedKph, e.MaxHeightM, e.MaxWeightT} {
				put(record[8+i*8:], math.Float64bits(v))
			}
			binary.LittleEndian.PutUint32(record[40:], classIDs[e.HwyType])
			if _, err = w.Write(record[:]); err != nil {
				return err
			}
		}
	}
	type cell struct{ key, id int64 }
	cells := make([]cell, len(ids))
	idx := &spatialIndex{cellSize: 0.01, minLat: bounds.MinLat, minLon: bounds.MinLon}
	for i, id := range ids {
		c, _ := r.g.coord(id)
		x, y := idx.cell(c.Lat, c.Lon)
		cells[i] = cell{cellKey(x, y), id}
	}
	sort.Slice(cells, func(i, j int) bool {
		if cells[i].key != cells[j].key {
			return cells[i].key < cells[j].key
		}
		return cells[i].id < cells[j].id
	})
	for _, c := range cells {
		put(record[:], uint64(c.key))
		put(record[8:], uint64(c.id))
		if _, err = w.Write(record[:16]); err != nil {
			return err
		}
	}
	if _, err = w.Write(meta); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = w.Flush(); err != nil {
		return err
	}
	return f.Sync()
}

func writeGraphSnapshot(ctx context.Context, path string, data []byte) (err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer func() {
		closeErr := f.Close()
		if err == nil {
			err = closeErr
		}
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	const chunkSize = 1 << 20
	for len(data) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := min(len(data), chunkSize)
		written, err := f.Write(data[:n])
		if err != nil {
			return err
		}
		if written != n {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Sync()
}

// OpenGraph opens a read-only, file-backed graph without rebuilding it from
// PBF or expanding coordinates and edges into maps. Close after all queries end.
func OpenGraph(path string) (*Router, error) {
	data, release, err := mapGraphFile(path)
	if err != nil {
		return nil, err
	}
	fail := func(e error) (*Router, error) { _ = release(); return nil, e }
	if len(data) < graphHeaderSize || string(data[:8]) != graphMagic {
		return fail(errors.New("unsupported or truncated graph"))
	}
	n, e, m := binary.LittleEndian.Uint64(data[8:]), binary.LittleEndian.Uint64(data[16:]), binary.LittleEndian.Uint64(data[24:])
	if n == 0 || n > uint64(len(data))/graphNodeSize || e > uint64(len(data))/graphEdgeSize || m > 64<<20 {
		return fail(errors.New("invalid graph sizes"))
	}
	edgesOffset := uint64(graphHeaderSize) + n*graphNodeSize
	cellsOffset := edgesOffset + e*graphEdgeSize
	metaOffset := cellsOffset + n*16
	if metaOffset > uint64(len(data)) || m != uint64(len(data))-metaOffset {
		return fail(io.ErrUnexpectedEOF)
	}
	var meta graphMetadata
	if err = json.Unmarshal(data[metaOffset:], &meta); err != nil {
		return fail(err)
	}
	if len(meta.Classes) == 0 && e > 0 {
		return fail(errors.New("missing graph classes"))
	}
	d := &diskGraph{data: data, nodes: int(n), edgeCount: int(e), edgesOffset: int(edgesOffset), cellsOffset: int(cellsOffset), classes: meta.Classes, release: release}
	var last int64
	for i := 0; i < d.nodes; i++ {
		b := data[graphHeaderSize+i*graphNodeSize:]
		id := int64(binary.LittleEndian.Uint64(b))
		start, count := binary.LittleEndian.Uint64(b[24:]), uint64(binary.LittleEndian.Uint32(b[32:]))
		if (i > 0 && id <= last) || start > e || count > e-start {
			return fail(errors.New("invalid graph node index"))
		}
		last = id
	}
	for i := 0; i < d.edgeCount; i++ {
		if int(binary.LittleEndian.Uint32(data[d.edgesOffset+i*graphEdgeSize+40:])) >= len(d.classes) {
			return fail(errors.New("invalid graph edge class"))
		}
	}
	b := CoordWindow{MinLat: math.Float64frombits(binary.LittleEndian.Uint64(data[32:])), MaxLat: math.Float64frombits(binary.LittleEndian.Uint64(data[40:])), MinLon: math.Float64frombits(binary.LittleEndian.Uint64(data[48:])), MaxLon: math.Float64frombits(binary.LittleEndian.Uint64(data[56:]))}
	idx := &spatialIndex{cellSize: 0.01, minLat: b.MinLat, minLon: b.MinLon, maxX: int32(math.Floor((b.MaxLat - b.MinLat) / 0.01)), maxY: int32(math.Floor((b.MaxLon - b.MinLon) / 0.01))}
	return &Router{g: Graph{store: d}, streets: meta.Streets, streetNameByNode: buildStreetNameIndex(meta.Streets), idx: idx, bounds: &b}, nil
}

// Close releases a file-backed graph. Map-built routers need no cleanup.
func (r *Router) Close() error {
	if r.g.store != nil && r.g.store.release != nil {
		err := r.g.store.release()
		r.g.store.release = nil
		return err
	}
	return nil
}
