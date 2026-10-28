// prepare-region builds the exact offline directory consumed by the Swift SDK.
// Run on a Mac or server and copy the resulting directory to an Apple app.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"simonwaldherr.de/go/osmmini/mobile"
	"syscall"
)

func main() {
	pbf := flag.String("pbf", "", "OSM PBF source")
	output := flag.String("output", "", "new region directory (required)")
	name := flag.String("name", "", "display name")
	maxNodes := flag.Int("max-import-nodes", 8_000_000, "road-node import limit; increase for large desktop builds")
	minZoom := flag.Int("min-zoom", 5, "first map zoom (5…14)")
	maxZoom := flag.Int("max-zoom", 14, "last map zoom (5…14)")
	memory := flag.Int64("tile-memory-mb", 256, "tinySQL tile import cache budget in MiB; not a total process limit")
	poiPreset := flag.String("poi-preset", "all", "points of interest: everyday, firefighting, outdoor, cycling, travel or all")
	flag.Parse()
	if *pbf == "" || *output == "" {
		flag.Usage()
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	m, err := mobile.Import(ctx, mobile.ImportOptions{PBF: *pbf, Destination: *output, Name: *name, MinZoom: *minZoom, MaxZoom: *maxZoom, MaxImportNodes: *maxNodes, TileMemoryBytes: *memory << 20, POIPreset: mobile.POIPreset(*poiPreset)}, func(p mobile.Progress) { fmt.Fprintf(os.Stderr, "%3.0f%% %s\n", p.Fraction*100, p.Phase) })
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(m)
}
