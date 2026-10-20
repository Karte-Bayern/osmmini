package mobile

import (
	"context"
	"errors"
	"math"
	"path/filepath"
	"testing"
)

// Cancel after the initial Engine.Tile check, once a tile has been read. This
// exercises cancellation of actual tile work without relying on wall time.
type cancelTileAfterRead struct {
	context.Context
	cancel context.CancelFunc
	checks int
}

func (ctx *cancelTileAfterRead) Err() error {
	ctx.checks++
	if ctx.checks == 2 {
		ctx.cancel()
	}
	return ctx.Context.Err()
}

func TestEngineTileCancellationAfterReadKeepsRegionUsable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "region")
	if _, err := Import(t.Context(), ImportOptions{
		PBF: fixture(t), Destination: path, MinZoom: 14, MaxZoom: 14,
	}, nil); err != nil {
		t.Fatal(err)
	}
	engine, err := Open(t.Context(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	const zoom = 14
	scale := math.Exp2(zoom)
	x := int((12.002 + 180) / 360 * scale)
	latitude := 48.002 * math.Pi / 180
	y := int((1 - math.Asinh(math.Tan(latitude))/math.Pi) / 2 * scale)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	if tile, err := engine.Tile(&cancelTileAfterRead{Context: ctx, cancel: cancel}, zoom, x, y); !errors.Is(err, context.Canceled) || len(tile.Features) != 0 {
		t.Fatalf("cancelled tile = %d features, %v", len(tile.Features), err)
	}
	tile, err := engine.Tile(t.Context(), zoom, x, y)
	if err != nil || len(tile.Features) == 0 {
		t.Fatalf("region unusable after cancellation: %d features, %v", len(tile.Features), err)
	}
}
