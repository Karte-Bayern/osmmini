package mobile

import (
	"bufio"
	"bytes"
	"compress/zlib"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Postings address the logical JSON byte stream, independent of compression.
// Fixed-size blocks make that offset directly addressable through a small disk
// directory. Neither opening a region nor searching retains the whole catalog.
const (
	searchDataMagic       = "OSMSDAT1"
	searchDataHeaderBytes = 48
	searchDataEntryBytes  = 16
	searchDataBlockBytes  = 32 << 10
	searchDataMaxEncoded  = searchDataBlockBytes + searchDataBlockBytes/16 + 1024
)

type searchDataWriter struct {
	ctx             context.Context
	file            *os.File
	writer          *bufio.Writer
	directory       *os.File
	directoryWriter *bufio.Writer
	compressor      *zlib.Writer
	encoded         bytes.Buffer
	buffer          [searchDataBlockBytes]byte
	used            int
	logical, offset uint64
	blocks          uint64
}

func newSearchDataWriter(ctx context.Context, file *os.File) (*searchDataWriter, error) {
	directory, err := os.CreateTemp(filepath.Dir(file.Name()), ".search-sort-data-*")
	if err != nil {
		return nil, err
	}
	s := &searchDataWriter{ctx: ctx, file: file, writer: bufio.NewWriterSize(file, 32<<10), directory: directory, directoryWriter: bufio.NewWriter(directory), offset: searchDataHeaderBytes}
	s.compressor = zlib.NewWriter(&s.encoded)
	_, err = s.writer.Write(make([]byte, searchDataHeaderBytes))
	if err != nil {
		s.close()
		return nil, err
	}
	return s, nil
}

func (s *searchDataWriter) close() {
	if s.directory != nil {
		s.directory.Close()
		os.Remove(s.directory.Name())
	}
}

func (s *searchDataWriter) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		if err := s.ctx.Err(); err != nil {
			return written, err
		}
		n := copy(s.buffer[s.used:], p)
		s.used += n
		s.logical += uint64(n)
		written += n
		p = p[n:]
		if s.used == len(s.buffer) {
			if err := s.flushBlock(); err != nil {
				return written, err
			}
		}
	}
	return written, nil
}

func (s *searchDataWriter) flushBlock() error {
	if err := s.ctx.Err(); err != nil {
		return err
	}
	if s.used == 0 {
		return nil
	}
	s.encoded.Reset()
	s.compressor.Reset(&s.encoded)
	if _, err := s.compressor.Write(s.buffer[:s.used]); err != nil {
		return err
	}
	if err := s.compressor.Close(); err != nil {
		return err
	}
	if s.encoded.Len() > searchDataMaxEncoded {
		return fmt.Errorf("compressed search block exceeds limit")
	}
	if _, err := s.writer.Write(s.encoded.Bytes()); err != nil {
		return err
	}
	var entry [searchDataEntryBytes]byte
	binary.LittleEndian.PutUint64(entry[:], s.offset)
	binary.LittleEndian.PutUint32(entry[8:], uint32(s.encoded.Len()))
	if _, err := s.directoryWriter.Write(entry[:]); err != nil {
		return err
	}
	s.offset += uint64(s.encoded.Len())
	s.blocks++
	s.used = 0
	return nil
}

func (s *searchDataWriter) finish() error {
	if err := s.flushBlock(); err != nil {
		return err
	}
	if err := s.directoryWriter.Flush(); err != nil {
		return err
	}
	if _, err := s.directory.Seek(0, io.SeekStart); err != nil {
		return err
	}
	var buffer [32 << 10]byte
	for {
		if err := s.ctx.Err(); err != nil {
			return err
		}
		n, err := s.directory.Read(buffer[:])
		if n > 0 {
			if _, writeErr := s.writer.Write(buffer[:n]); writeErr != nil {
				return writeErr
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
	}
	if err := s.writer.Flush(); err != nil {
		return err
	}
	var header [searchDataHeaderBytes]byte
	copy(header[:8], searchDataMagic)
	binary.LittleEndian.PutUint32(header[8:], 1)
	binary.LittleEndian.PutUint32(header[12:], searchDataBlockBytes)
	binary.LittleEndian.PutUint64(header[16:], s.logical)
	binary.LittleEndian.PutUint64(header[24:], s.blocks)
	binary.LittleEndian.PutUint64(header[32:], s.offset)
	binary.LittleEndian.PutUint32(header[40:], searchDataEntryBytes)
	if _, err := s.file.WriteAt(header[:], 0); err != nil {
		return err
	}
	return s.file.Sync()
}

func (s *searchReader) readDataHeader(size int64) error {
	var header [searchDataHeaderBytes]byte
	n, err := s.data.ReadAt(header[:], 0)
	if n < 8 || string(header[:8]) != searchDataMagic {
		s.dataBytes = size // Legacy JSONL remains directly readable.
		return nil
	}
	if err != nil || binary.LittleEndian.Uint32(header[8:]) != 1 || binary.LittleEndian.Uint32(header[12:]) != searchDataBlockBytes || binary.LittleEndian.Uint32(header[40:]) != searchDataEntryBytes || binary.LittleEndian.Uint32(header[44:]) != 0 {
		return fmt.Errorf("invalid compressed search data header")
	}
	logical, blocks, directory := binary.LittleEndian.Uint64(header[16:]), binary.LittleEndian.Uint64(header[24:]), binary.LittleEndian.Uint64(header[32:])
	if logical > uint64(^uint64(0)>>1) || directory < searchDataHeaderBytes || directory > uint64(size) || (uint64(size)-directory)%searchDataEntryBytes != 0 || blocks != (uint64(size)-directory)/searchDataEntryBytes || blocks != (logical+searchDataBlockBytes-1)/searchDataBlockBytes || blocks == 0 && directory != searchDataHeaderBytes {
		return fmt.Errorf("invalid compressed search data directory")
	}
	s.compressedData, s.dataBytes, s.dataBlocks, s.dataDirectory = true, int64(logical), blocks, int64(directory)
	return nil
}

// Each query owns its inflater and block buffers. Reusing the inflater avoids a
// 32 KiB DEFLATE window allocation for every random block, without a shared file
// cursor, region-sized cache, or retained oversized JSON records.
// Cache ranges stay on the query or stream, so pooled buffers never carry
// valid offsets from a previously searched region.
type searchDataWindow struct {
	directoryAt    uint64
	directoryCount uint64
	encodedAt      uint64
	encodedSize    uint64
	nextBlock      uint64
}

func (s *searchReader) readDataBlock(ctx context.Context, block uint64, scratch *searchScratch, window *searchDataWindow) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if block >= s.dataBlocks {
		return nil, fmt.Errorf("invalid compressed search block number")
	}
	// Sparse POI lookups keep exact-size reads. Only adjacent forward blocks
	// opt into read-ahead after the first block has been read successfully.
	continuing := window.nextBlock == block
	count := uint64(1)
	if block+1 < s.dataBlocks {
		count++
	}
	if block < window.directoryAt || block+count > window.directoryAt+window.directoryCount {
		// Keep single-block queries small. A continuing scan reads a bounded
		// directory window instead of making another syscall for each block.
		n := count
		if window.directoryCount != 0 && continuing {
			n = min(uint64(len(scratch.directory)/searchDataEntryBytes), s.dataBlocks-block)
		}
		if _, err := s.data.ReadAt(scratch.directory[:n*searchDataEntryBytes], s.dataDirectory+int64(block)*searchDataEntryBytes); err != nil {
			return nil, err
		}
		window.directoryAt, window.directoryCount = block, n
	}
	entryAt := (block - window.directoryAt) * searchDataEntryBytes
	entries := scratch.directory[entryAt : entryAt+count*searchDataEntryBytes]
	offset, size := binary.LittleEndian.Uint64(entries[:]), binary.LittleEndian.Uint32(entries[8:])
	if offset < searchDataHeaderBytes || offset > uint64(s.dataDirectory) || size == 0 || size > searchDataMaxEncoded || uint64(size) > uint64(s.dataDirectory)-offset || binary.LittleEndian.Uint32(entries[12:]) != 0 || block == 0 && offset != searchDataHeaderBytes || block+1 == s.dataBlocks && offset+uint64(size) != uint64(s.dataDirectory) || block+1 < s.dataBlocks && offset+uint64(size) != binary.LittleEndian.Uint64(entries[searchDataEntryBytes:]) {
		return nil, fmt.Errorf("invalid compressed search block bounds")
	}
	if offset < window.encodedAt || offset+uint64(size) > window.encodedAt+window.encodedSize {
		n := uint64(size)
		if window.encodedSize != 0 && continuing {
			n = min(uint64(len(scratch.encoded)), uint64(s.dataDirectory)-offset)
		}
		if _, err := s.data.ReadAt(scratch.encoded[:n], int64(offset)); err != nil {
			return nil, err
		}
		window.encodedAt, window.encodedSize = offset, n
	}
	encodedAt := offset - window.encodedAt
	encoded := scratch.encoded[encodedAt : encodedAt+uint64(size)]
	scratch.compressed.Reset(encoded)
	var err error
	if scratch.inflater == nil {
		scratch.inflater, err = zlib.NewReader(&scratch.compressed)
	} else {
		err = scratch.inflater.(zlib.Resetter).Reset(&scratch.compressed, nil)
	}
	if err != nil {
		return nil, fmt.Errorf("open compressed search block: %w", err)
	}
	length := min(uint64(searchDataBlockBytes), uint64(s.dataBytes)-block*searchDataBlockBytes)
	data := scratch.data[:length]
	if _, err := io.ReadFull(scratch.inflater, data); err != nil {
		return nil, fmt.Errorf("read compressed search block: %w", err)
	}
	// Reading through EOF verifies the zlib checksum. The extra-byte limit also
	// rejects a small compressed input that expands beyond the declared block.
	n, err := io.ReadFull(scratch.inflater, scratch.extra[:])
	if n != 0 || scratch.compressed.Len() != 0 {
		return nil, fmt.Errorf("invalid compressed search block length")
	}
	if err != io.EOF {
		return nil, fmt.Errorf("read compressed search block checksum: %w", err)
	}
	window.nextBlock = block + 1
	return data, nil
}

type searchRecords struct {
	search     *searchReader
	ctx        context.Context
	scratch    *searchScratch
	start, end uint64
	oversized  []byte
	window     searchDataWindow
}

func (r *searchRecords) read(offset uint64, length uint32) ([]byte, error) {
	s := r.search
	if length == 0 || length > maxSearchRecordBytes || offset > uint64(s.dataBytes) || uint64(length) > uint64(s.dataBytes)-offset {
		return nil, fmt.Errorf("invalid search record length or offset")
	}
	end := offset + uint64(length)
	if offset >= r.start && end <= r.end {
		return r.scratch.data[offset-r.start : end-r.start], nil
	}
	if s.compressedData {
		block := offset / searchDataBlockBytes
		if end <= (block+1)*searchDataBlockBytes {
			if err := r.loadBlock(block); err != nil {
				return nil, err
			}
			return r.scratch.data[offset-r.start : end-r.start], nil
		}
		// A record may cross block boundaries or occupy several blocks. Keep its
		// assembly buffer local to this query and cap it at the record limit.
		data := r.largeBuffer(length)
		for at := offset; at < end; {
			if at < r.start || at >= r.end {
				if err := r.loadBlock(at / searchDataBlockBytes); err != nil {
					return nil, err
				}
			}
			n := copy(data[at-offset:], r.scratch.data[at-r.start:min(r.end, end)-r.start])
			at += uint64(n)
		}
		return data, nil
	}
	if length > uint32(len(r.scratch.data)) {
		data := r.largeBuffer(length)
		_, err := s.data.ReadAt(data, int64(offset))
		return data, err
	}
	n := min(len(r.scratch.data), int(uint64(s.dataBytes)-offset))
	if _, err := s.data.ReadAt(r.scratch.data[:n], int64(offset)); err != nil {
		return nil, err
	}
	r.start, r.end = offset, offset+uint64(n)
	return r.scratch.data[:length], nil
}

func (r *searchRecords) largeBuffer(length uint32) []byte {
	if cap(r.oversized) < int(length) {
		r.oversized = make([]byte, length)
	}
	return r.oversized[:length]
}

func (r *searchRecords) loadBlock(block uint64) error {
	data, err := r.search.readDataBlock(r.ctx, block, r.scratch, &r.window)
	if err != nil {
		return err
	}
	r.start = block * searchDataBlockBytes
	r.end = r.start + uint64(len(data))
	return nil
}

// Sequential scans (settlement labels) use the same bounded decoder. ReadAt
// preserves the file cursor and allows concurrent random-access searches.
type searchDataStream struct {
	search  *searchReader
	ctx     context.Context
	scratch *searchScratch
	block   uint64
	pending []byte
	window  searchDataWindow
}

func (s *searchDataStream) Read(p []byte) (int, error) {
	if err := s.ctx.Err(); err != nil {
		return 0, err
	}
	if len(p) == 0 {
		return 0, nil
	}
	if len(s.pending) == 0 {
		if s.block == s.search.dataBlocks {
			return 0, io.EOF
		}
		var err error
		s.pending, err = s.search.readDataBlock(s.ctx, s.block, s.scratch, &s.window)
		if err != nil {
			return 0, err
		}
		s.block++
	}
	n := copy(p, s.pending)
	s.pending = s.pending[n:]
	return n, nil
}
