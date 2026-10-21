package mobile

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"
)

const poiLockFilename = ".poi-v1.lock"
const poiWorkDirectory = ".poi-work-v1"

var errPOILockUnavailable = errors.New("POI cache file locking is unavailable")

// Keep the lock inode even after releasing it: another process may already
// have opened it and be waiting. Process termination releases the OS lock.
func acquirePOILock(ctx context.Context, directory string) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(directory, poiLockFilename), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	for {
		if err := ctx.Err(); err != nil {
			file.Close()
			return nil, err
		}
		acquired, err := tryPOIFileLock(file)
		if err != nil {
			file.Close()
			return nil, err
		}
		if acquired {
			return func() { unlockPOIFile(file); _ = file.Close() }, nil
		}
		timer := time.NewTimer(25 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			file.Close()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

// Call only while holding the region's POI lock. In particular, never follow
// a symlink here or remove the importer's separately owned scratch files.
func cleanPOIWorkspace(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("POI workspace is not a directory")
	}
	return os.RemoveAll(path)
}
