//go:build !darwin && !ios && !linux && !freebsd && !netbsd && !openbsd && !dragonfly && !solaris

package mobile

import "os"

// Platforms without this lock implementation use private OS temporary files;
// they never clean or publish a shared cache without cross-process exclusion.
func tryPOIFileLock(*os.File) (bool, error) { return false, errPOILockUnavailable }
func unlockPOIFile(*os.File)                {}
