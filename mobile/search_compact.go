package mobile

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

// The index is split into independently readable blocks. Repeated terms share
// their prefix and record offsets are delta coded within each term. A small
// fixed-width directory remains on disk for binary prefix lookup; neither open
// nor search needs to load the regional index into memory.
const (
	searchCompactMagic       = "OSMSIDX2"
	searchCompactHeaderBytes = 48
	searchBlockPostings      = 128
	searchBlockMaxBytes      = searchBlockPostings * (2 + searchKeyBytes + binary.MaxVarintLen64 + binary.MaxVarintLen32)
)

type compactSearchWriter struct {
	ctx                       context.Context
	file                      *os.File
	writer                    *bufio.Writer
	directory                 *os.File
	directoryWriter           *bufio.Writer
	block                     []byte
	first, previous           string
	previousOffset            uint64
	blockCount, blocks, count uint64
	offset                    uint64
}

func newCompactSearchWriter(ctx context.Context, file *os.File, writer *bufio.Writer) (*compactSearchWriter, error) {
	directory, err := os.CreateTemp(filepath.Dir(file.Name()), ".search-sort-directory-*")
	if err != nil {
		return nil, err
	}
	s := &compactSearchWriter{ctx: ctx, file: file, writer: writer, directory: directory, directoryWriter: bufio.NewWriter(directory), block: make([]byte, 0, searchBlockMaxBytes), offset: searchCompactHeaderBytes}
	if _, err = writer.Write(make([]byte, searchCompactHeaderBytes)); err != nil {
		s.close()
		return nil, err
	}
	return s, nil
}

func (s *compactSearchWriter) close() {
	if s.directory != nil {
		s.directory.Close()
		os.Remove(s.directory.Name())
	}
}

func (s *compactSearchWriter) add(p searchPosting) error {
	if len(p.term) == 0 || len(p.term) > searchKeyBytes || p.length == 0 || p.length > maxSearchRecordBytes {
		return fmt.Errorf("invalid search posting")
	}
	if s.blockCount == searchBlockPostings {
		if err := s.flushBlock(); err != nil {
			return err
		}
	}
	if s.blockCount == 0 {
		s.first = p.term
	}
	shared := 0
	for shared < min(len(s.previous), len(p.term)) && s.previous[shared] == p.term[shared] {
		shared++
	}
	if s.previous > p.term || s.previous == p.term && p.offset < s.previousOffset {
		return fmt.Errorf("search postings out of order")
	}
	offset := p.offset
	if p.term == s.previous {
		offset -= s.previousOffset
	}
	s.block = append(s.block, byte(shared), byte(len(p.term)-shared))
	s.block = append(s.block, p.term[shared:]...)
	s.block = binary.AppendUvarint(s.block, offset)
	s.block = binary.AppendUvarint(s.block, uint64(p.length))
	s.previous, s.previousOffset = p.term, p.offset
	s.blockCount++
	s.count++
	return nil
}

func (s *compactSearchWriter) flushBlock() error {
	if err := s.ctx.Err(); err != nil {
		return err
	}
	if s.blockCount == 0 {
		return nil
	}
	if _, err := s.writer.Write(s.block); err != nil {
		return err
	}
	var entry [searchIndexBytes]byte
	copy(entry[:searchKeyBytes], s.first)
	binary.LittleEndian.PutUint64(entry[96:], s.offset)
	binary.LittleEndian.PutUint32(entry[104:], uint32(len(s.block)))
	binary.LittleEndian.PutUint32(entry[108:], uint32(s.blockCount))
	if _, err := s.directoryWriter.Write(entry[:]); err != nil {
		return err
	}
	s.offset += uint64(len(s.block))
	s.blocks++
	s.block, s.first, s.previous, s.previousOffset, s.blockCount = s.block[:0], "", "", 0, 0
	return nil
}

func (s *compactSearchWriter) finish() error {
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
	var header [searchCompactHeaderBytes]byte
	copy(header[:8], searchCompactMagic)
	binary.LittleEndian.PutUint32(header[8:], 2)
	binary.LittleEndian.PutUint32(header[12:], searchBlockPostings)
	binary.LittleEndian.PutUint64(header[16:], s.blocks)
	binary.LittleEndian.PutUint64(header[24:], s.count)
	binary.LittleEndian.PutUint64(header[32:], s.offset)
	binary.LittleEndian.PutUint32(header[40:], searchIndexBytes)
	if _, err := s.file.WriteAt(header[:], 0); err != nil {
		return err
	}
	return s.file.Sync()
}

func (s *searchReader) readIndexHeader(size int64) error {
	var header [searchCompactHeaderBytes]byte
	n, err := s.index.ReadAt(header[:], 0)
	if n < 8 || string(header[:8]) != searchCompactMagic {
		if size%searchIndexBytes != 0 || uint64(size/searchIndexBytes) > uint64(^uint(0)>>1) {
			return fmt.Errorf("invalid search index")
		}
		s.count = int(size / searchIndexBytes)
		return nil
	}
	if err != nil || binary.LittleEndian.Uint32(header[8:]) != 2 || binary.LittleEndian.Uint32(header[12:]) != searchBlockPostings || binary.LittleEndian.Uint32(header[40:]) != searchIndexBytes || binary.LittleEndian.Uint32(header[44:]) != 0 {
		return fmt.Errorf("invalid compact search header")
	}
	blocks, count, directory := binary.LittleEndian.Uint64(header[16:]), binary.LittleEndian.Uint64(header[24:]), binary.LittleEndian.Uint64(header[32:])
	if count > uint64(^uint(0)>>1) || count > ^uint64(0)-searchBlockPostings || directory < searchCompactHeaderBytes || directory > uint64(size) || (uint64(size)-directory)%searchIndexBytes != 0 || blocks != (uint64(size)-directory)/searchIndexBytes || blocks != (count+searchBlockPostings-1)/searchBlockPostings {
		return fmt.Errorf("invalid compact search directory")
	}
	s.compact, s.blocks, s.count, s.directory = true, int(blocks), int(count), int64(directory)
	return nil
}

type searchPostingIterator struct {
	search     *searchReader
	scratch    *searchScratch
	position   int
	batch      []byte
	block      int
	remaining  int
	encoded    []byte
	term       [searchKeyBytes]byte
	termLength int
	offset     uint64
	first      []byte
	lastTerm   [searchKeyBytes]byte
	lastLength int
	lastOffset uint64
	windowAt   int
	windowSize int
}

func searchTerm(b []byte) []byte {
	if end := bytes.IndexByte(b, 0); end >= 0 {
		return b[:end]
	}
	return b
}

// A directory lookup narrows to nearby entries near the end of its binary
// search. Read one bounded window into the existing query scratch instead of
// issuing a file read for every comparison. Compact scans reuse the same
// window while advancing through the directory.
func (i *searchPostingIterator) indexEntry(position int) ([]byte, error) {
	if position < i.windowAt || position >= i.windowAt+i.windowSize {
		count, base := i.search.count, int64(0)
		if i.search.compact {
			count, base = i.search.blocks, i.search.directory
		}
		const entries = 64
		at := position / entries * entries
		n := min(entries, count-at)
		if _, err := i.search.index.ReadAt(i.scratch.postings[:n*searchIndexBytes], base+int64(at)*searchIndexBytes); err != nil {
			return nil, err
		}
		i.windowAt, i.windowSize = at, n
	}
	at := (position - i.windowAt) * searchIndexBytes
	return i.scratch.postings[at : at+searchIndexBytes], nil
}

func (s *searchReader) postingsFrom(key []byte, scratch *searchScratch) (*searchPostingIterator, error) {
	iterator := &searchPostingIterator{search: s, scratch: scratch}
	var readErr error
	if !s.compact {
		iterator.position = sort.Search(s.count, func(i int) bool {
			b, err := iterator.indexEntry(i)
			if err != nil {
				readErr = err
				return true
			}
			return bytes.Compare(searchTerm(b[:searchKeyBytes]), key) >= 0
		})
	} else {
		iterator.block = sort.Search(s.blocks, func(i int) bool {
			b, err := iterator.indexEntry(i)
			if err != nil {
				readErr = err
				return true
			}
			return bytes.Compare(searchTerm(b[:searchKeyBytes]), key) >= 0
		})
		// The preceding block may start before the query while containing its
		// first matching term, including a term split across many blocks.
		if iterator.block > 0 {
			iterator.block--
		}
	}
	return iterator, readErr
}

func (i *searchPostingIterator) next() ([]byte, uint64, uint32, error) {
	if !i.search.compact {
		if len(i.batch) == 0 {
			if i.position == i.search.count {
				return nil, 0, 0, io.EOF
			}
			n := min(len(i.scratch.postings)/searchIndexBytes, i.search.count-i.position)
			i.batch = i.scratch.postings[:n*searchIndexBytes]
			if _, err := i.search.index.ReadAt(i.batch, int64(i.position)*searchIndexBytes); err != nil {
				return nil, 0, 0, err
			}
		}
		b := i.batch[:searchIndexBytes]
		i.batch = i.batch[searchIndexBytes:]
		i.position++
		return searchTerm(b[:searchKeyBytes]), binary.LittleEndian.Uint64(b[96:]), binary.LittleEndian.Uint32(b[104:]), nil
	}
	if i.remaining == 0 {
		if len(i.encoded) != 0 {
			return nil, 0, 0, fmt.Errorf("extra compact search block data")
		}
		if i.block == i.search.blocks {
			return nil, 0, 0, io.EOF
		}
		entry, err := i.indexEntry(i.block)
		if err != nil {
			return nil, 0, 0, err
		}
		offset, size, count := binary.LittleEndian.Uint64(entry[96:]), binary.LittleEndian.Uint32(entry[104:]), binary.LittleEndian.Uint32(entry[108:])
		if offset < searchCompactHeaderBytes || offset > uint64(i.search.directory) || uint64(size) > uint64(i.search.directory)-offset || size == 0 || size > searchBlockMaxBytes || count == 0 || count > searchBlockPostings || i.block < i.search.blocks-1 && count != searchBlockPostings || i.block == i.search.blocks-1 && uint64(count) != uint64(i.search.count)-uint64(i.block)*searchBlockPostings {
			return nil, 0, 0, fmt.Errorf("invalid compact search block")
		}
		i.first = searchTerm(entry[:searchKeyBytes])
		if len(i.first) == 0 {
			return nil, 0, 0, fmt.Errorf("empty compact search key")
		}
		i.encoded = i.scratch.block[:size]
		if _, err := i.search.index.ReadAt(i.encoded, int64(offset)); err != nil {
			return nil, 0, 0, err
		}
		i.remaining, i.termLength, i.offset = int(count), 0, 0
		i.block++
	}
	if len(i.encoded) < 2 {
		return nil, 0, 0, fmt.Errorf("truncated compact search posting")
	}
	shared, suffix := int(i.encoded[0]), int(i.encoded[1])
	i.encoded = i.encoded[2:]
	if shared > i.termLength || shared+suffix == 0 || shared+suffix > searchKeyBytes || suffix > len(i.encoded) {
		return nil, 0, 0, fmt.Errorf("invalid compact search term")
	}
	same := shared == i.termLength && suffix == 0
	copy(i.term[shared:], i.encoded[:suffix])
	i.termLength = shared + suffix
	i.encoded = i.encoded[suffix:]
	order := bytes.Compare(i.term[:i.termLength], i.lastTerm[:i.lastLength])
	if i.lastLength != 0 && order < 0 {
		return nil, 0, 0, fmt.Errorf("compact search terms out of order")
	}
	if i.first == nil && (order == 0) != same {
		return nil, 0, 0, fmt.Errorf("invalid repeated compact search term")
	}
	offset, n := binary.Uvarint(i.encoded)
	if n <= 0 {
		return nil, 0, 0, fmt.Errorf("invalid compact search offset")
	}
	i.encoded = i.encoded[n:]
	length, n := binary.Uvarint(i.encoded)
	if n <= 0 || length == 0 || length > maxSearchRecordBytes {
		return nil, 0, 0, fmt.Errorf("invalid compact search length")
	}
	i.encoded = i.encoded[n:]
	if same {
		if offset > ^uint64(0)-i.offset {
			return nil, 0, 0, fmt.Errorf("compact search offset overflow")
		}
		offset += i.offset
	}
	if i.lastLength != 0 && order == 0 && offset < i.lastOffset {
		return nil, 0, 0, fmt.Errorf("compact search offsets out of order")
	}
	i.offset = offset
	copy(i.lastTerm[:], i.term[:i.termLength])
	i.lastLength, i.lastOffset = i.termLength, offset
	if i.first != nil {
		if !bytes.Equal(i.first, i.term[:i.termLength]) {
			return nil, 0, 0, fmt.Errorf("compact search directory key mismatch")
		}
		i.first = nil
	}
	i.remaining--
	if i.remaining == 0 && len(i.encoded) != 0 {
		return nil, 0, 0, fmt.Errorf("extra compact search block data")
	}
	return i.term[:i.termLength], offset, uint32(length), nil
}
