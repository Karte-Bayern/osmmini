package mobile

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// cleanMapImportScratch removes work left by a terminated tile build. These
// directories contain neither resumable graph/search checkpoints nor source
// data. Call only inside the import's private staging directory while holding
// its destination lock, before starting another tile build.
func cleanMapImportScratch(ctx context.Context, stage string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	entries, err := os.ReadDir(stage)
	if err != nil {
		return fmt.Errorf("read map import workspace: %w", err)
	}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := entry.Name()
		if name != "basemap.ttiles.rollback" &&
			!hasScratchSuffix(name, ".tinytiles-pbf-") &&
			!hasScratchSuffix(name, ".tinysql-artifact-") {
			continue
		}
		// Both builders create directories. Do not remove an unrelated regular
		// file merely because its name resembles one. RemoveAll unlinks a
		// symbolic link itself without traversing its target.
		if !entry.IsDir() && entry.Type()&os.ModeSymlink == 0 {
			continue
		}
		if err := os.RemoveAll(filepath.Join(stage, name)); err != nil {
			return fmt.Errorf("remove interrupted map build %s: %w", name, err)
		}
	}
	return ctx.Err()
}

func hasScratchSuffix(name, prefix string) bool {
	return len(name) > len(prefix) && strings.HasPrefix(name, prefix)
}
