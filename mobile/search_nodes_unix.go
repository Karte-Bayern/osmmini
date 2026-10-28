//go:build darwin || linux || freebsd || openbsd || netbsd

package mobile

import (
	"os"
	"syscall"
)

func mapSearchNodeFile(file *os.File, size int64) ([]byte, func() error, error) {
	if size <= 0 || uint64(size) > uint64(^uint(0)>>1) {
		return nil, nil, os.ErrInvalid
	}
	data, err := syscall.Mmap(int(file.Fd()), 0, int(size), syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return nil, nil, err
	}
	return data, func() error { return syscall.Munmap(data) }, nil
}
