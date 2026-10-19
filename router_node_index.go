package osmmini

import (
	"context"
	"encoding/binary"
	"slices"
)

// Use the compact file's uint32 node indices throughout a turn-free search.
// Resolve the API endpoints once and translate the final path back to OSM IDs.
// Search maps remain lazy: short routes must not allocate region-sized arrays.
// Territory-cost callbacks retain the ID-based path, as do legacy V1 graphs.
func (r *Router) indexNodeSearch(ctx context.Context, from, to int64, opt RouteOptions, wantPath bool) ([]int64, float64, error) {
	if from == to {
		if wantPath {
			return []int64{from}, 0, nil
		}
		return nil, 0, nil
	}
	d := r.g.store
	start, target := d.nodeIndex(from), d.nodeIndex(to)
	if start < 0 {
		return nil, 0, ErrRouteStartUnreachable
	}
	if target < 0 {
		return nil, 0, ErrRouteTargetUnreachable
	}
	if _, count := d.edgeRange(start); count == 0 && opt.Engine != EngineDijkstraNode {
		return nil, 0, ErrRouteStartUnreachable
	}
	fromIndex, toIndex := uint32(start), uint32(target)
	eval := newRouteEvaluator(opt)
	heuristic := newRouteHeuristic(d.coordAt(target), opt)
	dist := make(map[uint32]float64, min(64, d.nodes))
	var previous map[uint32]uint32
	if wantPath {
		previous = make(map[uint32]uint32, min(64, d.nodes))
	}
	dist[fromIndex] = 0
	pq := nodeValueHeap[uint32]{}
	pq.push(nodeCandidate[uint32]{id: fromIndex, priority: heuristic.estimateCoordinate(d.coordAt(start))})
	for pops := 0; len(pq) > 0; pops++ {
		if ctx != nil && pops%256 == 0 {
			if err := ctx.Err(); err != nil {
				return nil, 0, err
			}
		}
		current := pq.pop()
		if current.dist != dist[current.id] {
			continue
		}
		if current.id == toIndex {
			if !wantPath {
				return nil, current.dist, nil
			}
			path := make([]int64, 0, 64)
			for node := toIndex; ; node = previous[node] {
				path = append(path, int64(binary.LittleEndian.Uint64(d.nodeRecord(int(node)))))
				if node == fromIndex {
					break
				}
			}
			slices.Reverse(path)
			return path, current.dist, nil
		}
		for it := d.edgesAt(int(current.id)); it.next(); {
			edge := it.edge()
			if !eval.edgeAllowed(edge) {
				continue
			}
			next := it.targetIndex()
			cost := current.dist + eval.baseEdgeCost(edge)
			if old, exists := dist[next]; exists && cost >= old {
				continue
			}
			dist[next] = cost
			if wantPath {
				previous[next] = current.id
			}
			var estimate float64
			if !heuristic.disabled {
				estimate = heuristic.estimateCoordinate(d.coordAt(int(next)))
			}
			pq.push(nodeCandidate[uint32]{id: next, dist: cost, priority: cost + estimate})
		}
	}
	return nil, 0, ErrRouteNoPath
}
