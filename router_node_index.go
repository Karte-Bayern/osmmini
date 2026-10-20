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
	costs := newCompactRouteCosts(eval)
	heuristic := newRouteHeuristic(d.coordAt(target), opt)
	labels := newIndexNodeLabels(min(64, d.nodes), wantPath)
	labels.set(fromIndex, 0, 0)
	pq := nodeValueHeap[uint32]{}
	pq.push(nodeCandidate[uint32]{id: fromIndex, priority: heuristic.estimateCoordinate(d.coordAt(start))})
	for pops := 0; len(pq) > 0; pops++ {
		if ctx != nil && pops%256 == 0 {
			if err := ctx.Err(); err != nil {
				return nil, 0, err
			}
		}
		current := pq.pop()
		if distance, _ := labels.distance(current.id); current.dist != distance {
			continue
		}
		if current.id == toIndex {
			if !wantPath {
				return nil, current.dist, nil
			}
			path := make([]int64, 0, 64)
			for node := toIndex; ; node = labels.paths[node].previous {
				path = append(path, int64(binary.LittleEndian.Uint64(d.nodeRecord(int(node)))))
				if node == fromIndex {
					break
				}
			}
			slices.Reverse(path)
			return path, current.dist, nil
		}
		for it := d.edgesAt(int(current.id)); it.next(); {
			next, attribute, distance := it.compactFields()
			edgeCost, allowed := costs.edgeCost(d, attribute, distance)
			if !allowed {
				continue
			}
			cost := current.dist + edgeCost
			if old, exists := labels.distance(next); exists && cost >= old {
				continue
			}
			labels.set(next, cost, current.id)
			var estimate float64
			if !heuristic.disabled {
				estimate = heuristic.estimateCoordinate(d.coordAt(int(next)))
			}
			pq.push(nodeCandidate[uint32]{id: next, dist: cost, priority: cost + estimate})
		}
	}
	return nil, 0, ErrRouteNoPath
}

// A path query updates both fields together. Keeping them in one map avoids a
// second lookup and growth of a separate predecessor map for every relaxed node.
// Cost-only queries still store just distances, and both maps grow lazily.
type indexNodeLabel struct {
	distance float64
	previous uint32
}

type indexNodeLabels struct {
	distances map[uint32]float64
	paths     map[uint32]indexNodeLabel
}

func newIndexNodeLabels(capacity int, wantPath bool) indexNodeLabels {
	if wantPath {
		return indexNodeLabels{paths: make(map[uint32]indexNodeLabel, capacity)}
	}
	return indexNodeLabels{distances: make(map[uint32]float64, capacity)}
}

func (labels indexNodeLabels) distance(node uint32) (float64, bool) {
	if labels.paths != nil {
		label, exists := labels.paths[node]
		return label.distance, exists
	}
	distance, exists := labels.distances[node]
	return distance, exists
}

func (labels indexNodeLabels) set(node uint32, distance float64, previous uint32) {
	if labels.paths != nil {
		labels.paths[node] = indexNodeLabel{distance: distance, previous: previous}
		return
	}
	labels.distances[node] = distance
}
