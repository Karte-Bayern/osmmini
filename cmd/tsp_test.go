package main

import (
	"context"
	"errors"
	"math"
	"math/rand"
	"testing"

	osmmini "simonwaldherr.de/go/osmmini"
)

func tspFixture(n int, seed int64) (*server, []stopR, osmmini.RouteOptions) {
	random := rand.New(rand.NewSource(seed))
	coords := make(map[int64]osmmini.Coord)
	adj := make(map[int64][]osmmini.Edge)
	stops := make([]stopR, n)
	for i := 0; i < n+2; i++ {
		id := int64(i + 1)
		coords[id] = osmmini.Coord{Lat: 48 + float64(i)*0.001, Lon: 12}
		for j := 0; j < n+2; j++ {
			if i != j {
				adj[id] = append(adj[id], osmmini.Edge{To: int64(j + 1), DistM: float64(1 + random.Intn(100)), SpeedKph: 50, HwyType: "residential"})
			}
		}
		if i < n {
			stops[i] = stopR{node: int64(i + 2)}
		}
	}
	return &server{router: osmmini.NewRouterFromGraph(coords, adj)}, stops, osmmini.RouteOptions{Engine: osmmini.EngineDijkstra, Objective: osmmini.ObjectiveDistance}
}

func TestTSPExactMatchesBruteForceDirectedCosts(t *testing.T) {
	for seed := int64(0); seed < 10; seed++ {
		s, stops, opt := tspFixture(5, seed)
		pre := []uint64{0, 0, 1, 0, 2} // 0 before 2, 1 before 4
		cost := make([][]float64, 7)
		for i := range cost {
			cost[i] = make([]float64, 7)
			for j := range cost[i] {
				c, err := s.router.RouteCostWithOptions(context.Background(), int64(i+1), int64(j+1), opt)
				if err != nil {
					t.Fatal(err)
				}
				cost[i][j] = c
			}
		}
		evaluate := func(order []int) float64 {
			total := 0.0
			prev := 0
			mask := uint64(0)
			for _, idx := range order {
				if mask&pre[idx] != pre[idx] {
					return math.Inf(1)
				}
				mask |= 1 << uint(idx)
				total += cost[prev][idx+1]
				prev = idx + 1
			}
			return total + cost[prev][6]
		}
		best := math.Inf(1)
		var visit func([]int, uint64)
		visit = func(order []int, mask uint64) {
			if len(order) == 5 {
				best = math.Min(best, evaluate(order))
				return
			}
			for i := 0; i < 5; i++ {
				if mask&(1<<uint(i)) == 0 {
					visit(append(order, i), mask|(1<<uint(i)))
				}
			}
		}
		visit(nil, 0)
		order, err := s.tspExact(context.Background(), 1, 7, stops, pre, opt)
		if err != nil {
			t.Fatal(err)
		}
		if len(order) != 5 || evaluate(order) != best {
			t.Fatalf("seed %d: order %v cost %v, optimum %v", seed, order, evaluate(order), best)
		}
	}
}

func TestTSPRejectsCyclesAndCancellationBeforeRouting(t *testing.T) {
	s := &server{} // A valid early rejection must not access a router.
	stops := make([]stopR, 2)
	for _, solve := range []func(context.Context, int64, int64, []stopR, []uint64, osmmini.RouteOptions) ([]int, error){s.tspExact, s.tspGreedy} {
		if _, err := solve(context.Background(), 1, 2, stops, []uint64{2, 1}, osmmini.RouteOptions{}); err == nil {
			t.Fatal("cycle accepted")
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := solve(ctx, 1, 2, stops, []uint64{0, 0}, osmmini.RouteOptions{}); !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation = %v", err)
		}
	}
}

func TestTSP2OptCanImproveFirstStop(t *testing.T) {
	coords := make(map[int64]osmmini.Coord)
	adj := make(map[int64][]osmmini.Edge)
	// Directed chain: start -> stop 1 -> stop 0 -> stop 2 -> stop 3 -> end.
	chain := []int64{1, 3, 2, 4, 5, 6}
	for _, id := range chain {
		coords[id] = osmmini.Coord{Lat: 48, Lon: 12}
		for _, to := range chain {
			if id != to {
				adj[id] = append(adj[id], osmmini.Edge{To: to, DistM: 100, SpeedKph: 50, HwyType: "residential"})
			}
		}
	}
	for i := 0; i < len(chain)-1; i++ {
		adj[chain[i]] = append(adj[chain[i]], osmmini.Edge{To: chain[i+1], DistM: 1, SpeedKph: 50, HwyType: "residential"})
	}
	s := &server{router: osmmini.NewRouterFromGraph(coords, adj)}
	stops := []stopR{{node: 2}, {node: 3}, {node: 4}, {node: 5}}
	opt := osmmini.RouteOptions{Engine: osmmini.EngineDijkstra, Objective: osmmini.ObjectiveDistance}
	order := s.tsp2opt(context.Background(), 1, 6, stops, make([]uint64, 4), opt, []int{0, 1, 2, 3})
	if order[0] != 1 {
		t.Fatalf("first stop never improved: %v", order)
	}
	order = s.tsp2opt(context.Background(), 1, 6, stops, []uint64{0, 1, 0, 0}, opt, []int{0, 1, 2, 3})
	seen := uint64(0)
	for _, i := range order {
		if i == 1 && seen&1 == 0 {
			t.Fatal("2-opt violated dependency")
		}
		seen |= 1 << uint(i)
	}
}

func BenchmarkTSPExact12(b *testing.B) {
	s, stops, opt := tspFixture(12, 42)
	pre := make([]uint64, 12)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := s.tspExact(context.Background(), 1, 14, stops, pre, opt); err != nil {
			b.Fatal(err)
		}
	}
}

func TestTSPExactKeepsStopsAtSameNodeAndRejectsDisconnectedTour(t *testing.T) {
	s, _, opt := tspFixture(2, 1)
	stops := []stopR{{node: 2}, {node: 2}}
	order, err := s.tspExact(context.Background(), 1, 4, stops, []uint64{2, 0}, opt)
	if err != nil || len(order) != 2 || order[0] != 1 || order[1] != 0 {
		t.Fatalf("coincident stops: %v, %v", order, err)
	}
	s.router = osmmini.NewRouterFromGraph(map[int64]osmmini.Coord{1: {}, 2: {}, 3: {}, 4: {}}, nil)
	if _, err := s.tspExact(context.Background(), 1, 4, stops, []uint64{0, 0}, opt); err == nil {
		t.Fatal("disconnected tour accepted")
	}
}

func TestTSPGreedyPreservesAllStopsAndDependencies(t *testing.T) {
	s, stops, opt := tspFixture(20, 41)
	pre := make([]uint64, 20)
	for i := 1; i < 20; i += 2 {
		pre[i] = 1 << uint(i-1)
	}
	order, err := s.tspGreedy(context.Background(), 1, 22, stops, pre, opt)
	if err != nil {
		t.Fatal(err)
	}
	mask := uint64(0)
	for _, i := range order {
		if i < 0 || i >= 20 || mask&(1<<uint(i)) != 0 || mask&pre[i] != pre[i] {
			t.Fatalf("invalid order: %v", order)
		}
		mask |= 1 << uint(i)
	}
	if mask != (1<<20)-1 {
		t.Fatalf("missing stops: %v", order)
	}
}

// Cancel during a cost lookup deterministically, without timing-sensitive sleeps.
type cancelOnCheck struct {
	context.Context
	cancel    context.CancelFunc
	remaining int
}

func (c *cancelOnCheck) Err() error {
	c.remaining--
	if c.remaining == 0 {
		c.cancel()
	}
	return c.Context.Err()
}
func TestTSPCancellationDuringCostLookup(t *testing.T) {
	s, stops, opt := tspFixture(5, 7)
	for _, solve := range []func(context.Context, int64, int64, []stopR, []uint64, osmmini.RouteOptions) ([]int, error){s.tspExact, s.tspGreedy} {
		base, cancel := context.WithCancel(context.Background())
		ctx := &cancelOnCheck{Context: base, cancel: cancel, remaining: 4}
		_, err := solve(ctx, 1, 7, stops, make([]uint64, 5), opt)
		cancel()
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation became a routing error: %v", err)
		}
	}
}
