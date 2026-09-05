package main

import (
	"context"
	"errors"
	"math"

	osmmini "simonwaldherr.de/go/osmmini"
)

// Costs are scoped to one solve and its options; one-way roads stay directed.
func (s *server) tripCosts(ctx context.Context, opt osmmini.RouteOptions) func(int64, int64) (float64, error) {
	type pair struct{ from, to int64 }
	type result struct {
		cost float64
		err  error
	}
	cache := make(map[pair]result)
	return func(from, to int64) (float64, error) {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		key := pair{from, to}
		if value, ok := cache[key]; ok {
			return value.cost, value.err
		}
		cost, err := s.router.RouteCostWithOptions(ctx, from, to, opt)
		cache[key] = result{cost, err}
		return cost, err
	}
}

func validateTSP(ctx context.Context, n int, pre []uint64, maxStops int) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if n > maxStops || len(pre) != n {
		return errors.New("tsp: invalid stop or dependency count")
	}
	visited := uint64(0)
	for count := 0; count < n; count++ {
		found := false
		for i := 0; i < n; i++ {
			bit := uint64(1) << uint(i)
			if visited&bit == 0 && visited&pre[i] == pre[i] {
				visited |= bit
				found = true
				break
			}
		}
		if !found {
			return errors.New("tsp: dependency cycle or invalid prerequisite")
		}
	}
	return nil
}

func (s *server) tspExact(ctx context.Context, startNode, endNode int64, stops []stopR, pre []uint64, opt osmmini.RouteOptions) ([]int, error) {
	n := len(stops)
	if err := validateTSP(ctx, n, pre, 16); err != nil {
		return nil, err
	}
	cost := s.tripCosts(ctx, opt)
	if n == 0 {
		return nil, nil
	}

	inf := math.MaxFloat64 / 4

	costStart := make([]float64, n)
	costEnd := make([]float64, n)
	costBetween := make([][]float64, n)
	for i := 0; i < n; i++ {
		costBetween[i] = make([]float64, n)
	}

	for i := 0; i < n; i++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		c, err := cost(startNode, stops[i].node)
		if err != nil {
			costStart[i] = inf
		} else {
			costStart[i] = c
		}
		c2, err := cost(stops[i].node, endNode)
		if err != nil {
			costEnd[i] = inf
		} else {
			costEnd[i] = c2
		}
	}

	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if i == j {
				costBetween[i][j] = inf
				continue
			}
			c, err := cost(stops[i].node, stops[j].node)
			if err != nil {
				costBetween[i][j] = inf
			} else {
				costBetween[i][j] = c
			}
		}
	}

	size := 1 << uint(n)
	dp := make([]float64, size*n)
	par := make([]int16, size*n)
	for i := range dp {
		dp[i] = inf
		par[i] = -1
	}

	for i := 0; i < n; i++ {
		if pre[i] == 0 && costStart[i] < inf {
			m := 1 << uint(i)
			dp[(m)*n+(i)] = costStart[i]
			par[(m)*n+(i)] = -1
		}
	}

	for m := 0; m < size; m++ {
		if m%256 == 0 {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
		}
		for last := 0; last < n; last++ {
			if dp[(m)*n+(last)] >= inf {
				continue
			}
			for nxt := 0; nxt < n; nxt++ {
				if (m & (1 << uint(nxt))) != 0 {
					continue
				}
				if (uint64(m) & pre[nxt]) != pre[nxt] {
					continue
				}
				nm := m | (1 << uint(nxt))
				c := dp[(m)*n+(last)] + costBetween[last][nxt]
				if c < dp[(nm)*n+(nxt)] {
					dp[(nm)*n+(nxt)] = c
					par[(nm)*n+(nxt)] = int16(last)
				}
			}
		}
	}

	all := size - 1
	best := inf
	bestLast := -1
	for last := 0; last < n; last++ {
		if dp[(all)*n+(last)] >= inf || costEnd[last] >= inf {
			continue
		}
		c := dp[(all)*n+(last)] + costEnd[last]
		if c < best {
			best = c
			bestLast = last
		}
	}
	if bestLast == -1 {
		return nil, errors.New("tsp: no feasible order (unreachable legs or dependency cycle)")
	}

	order := make([]int, 0, n)
	m := all
	cur := bestLast
	for cur >= 0 {
		order = append(order, cur)
		p := par[(m)*n+(cur)]
		m = m &^ (1 << uint(cur))
		if p < 0 {
			break
		}
		cur = int(p)
	}
	for i, j := 0, len(order)-1; i < j; i, j = i+1, j-1 {
		order[i], order[j] = order[j], order[i]
	}
	return order, nil
}

func (s *server) tspGreedy(ctx context.Context, startNode, endNode int64, stops []stopR, pre []uint64, opt osmmini.RouteOptions) ([]int, error) {
	n := len(stops)
	if err := validateTSP(ctx, n, pre, 60); err != nil {
		return nil, err
	}
	cost := s.tripCosts(ctx, opt)
	if n == 0 {
		return nil, nil
	}
	visited := uint64(0)
	order := make([]int, 0, n)
	curNode := startNode

	for len(order) < n {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		best := math.MaxFloat64
		bestIdx := -1
		for i := 0; i < n; i++ {
			bit := uint64(1) << uint64(i)
			if (visited & bit) != 0 {
				continue
			}
			if (visited & pre[i]) != pre[i] {
				continue
			}
			c, err := cost(curNode, stops[i].node)
			if err != nil {
				if err := ctx.Err(); err != nil {
					return nil, err
				}
				continue
			}
			if c < best {
				best = c
				bestIdx = i
			}
		}
		if bestIdx == -1 {
			return nil, errors.New("tsp: no eligible next stop (dependency cycle or unreachable stop)")
		}
		order = append(order, bestIdx)
		visited |= uint64(1) << uint64(bestIdx)
		curNode = stops[bestIdx].node
	}

	// 2-opt improvement: try swapping segments to find shorter tours
	if n >= 4 {
		order = tsp2optCosts(ctx, startNode, endNode, stops, pre, order, cost)
	}

	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return order, nil
}

// tsp2opt applies the 2-opt local search improvement to the given tour order.
// It repeatedly reverses sub-segments of the tour if doing so reduces total cost,
// while respecting dependency constraints. Route costs are cached to avoid
// redundant pathfinding computations.
func (s *server) tsp2opt(ctx context.Context, startNode, endNode int64, stops []stopR, pre []uint64, opt osmmini.RouteOptions, order []int) []int {
	return tsp2optCosts(ctx, startNode, endNode, stops, pre, order, s.tripCosts(ctx, opt))
}

func tsp2optCosts(ctx context.Context, startNode, endNode int64, stops []stopR, pre []uint64, order []int, cost func(int64, int64) (float64, error)) []int {
	n := len(order)
	if n < 4 {
		return order
	}

	cachedCost := func(from, to int64) float64 {
		c, err := cost(from, to)
		if err != nil {
			return math.MaxFloat64
		}
		return c
	}

	// helper to compute total tour cost for a given order
	tourCost := func(ord []int) float64 {
		total := 0.0
		prev := startNode
		for _, idx := range ord {
			c := cachedCost(prev, stops[idx].node)
			if c >= math.MaxFloat64/4 {
				return math.MaxFloat64
			}
			total += c
			prev = stops[idx].node
		}
		c := cachedCost(prev, endNode)
		if c >= math.MaxFloat64/4 {
			return math.MaxFloat64
		}
		total += c
		return total
	}

	// check if an order respects all dependency constraints
	depsOK := func(ord []int) bool {
		mask := uint64(0)
		for _, idx := range ord {
			if (mask & pre[idx]) != pre[idx] {
				return false
			}
			mask |= 1 << uint64(idx)
		}
		return true
	}

	candidate := make([]int, n)
	bestCost := tourCost(order)
	improved := true
	for improved {
		improved = false
		for i := -1; i < n-1; i++ {
			for j := i + 2; j < n; j++ {
				// Directed roads require evaluating the reversed interior too.
				if ctx.Err() != nil {
					return order
				}
				newOrder := candidate
				copy(newOrder, order)
				for l, r := i+1, j; l < r; l, r = l+1, r-1 {
					newOrder[l], newOrder[r] = newOrder[r], newOrder[l]
				}
				if !depsOK(newOrder) {
					continue
				}
				newCost := tourCost(newOrder)
				if newCost < bestCost {
					copy(order, newOrder)
					bestCost = newCost
					improved = true
				}
			}
		}
	}
	return order
}
