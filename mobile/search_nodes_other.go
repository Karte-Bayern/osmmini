//go:build !darwin && !linux && !freebsd && !openbsd && !netbsd

package mobile

import "os"

// Other platforms use searchNodeTable's bounded file window.
func mapSearchNodeFile(file *os.File, size int64) ([]byte, func() error, error) {
	return nil, nil, nil
}
