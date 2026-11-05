//go:build linux

package files

// fs.tail: a log file as it grows (tail -F). The stream answers with the
// file's size and where the first chunk starts (the last N lines), sends
// that chunk, then every new byte as it is written. A file that is truncated
// or replaced (log rotation) is followed too: a control frame tells the
// client, and the new file is read from its start.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"syscall"
	"time"

	"aurora3/internal/wire"
)

const (
	tailFirstMax = 4 << 20  // the first chunk is at most this much
	tailBehind   = 16 << 20 // further behind than this: skip ahead
)

func (s *Env) fsTail(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var a struct {
		Root  string `json:"root"`
		Path  string `json:"path"`
		Lines int    `json:"lines"`
		// From resumes at this offset (a reconnect); ignored when the file is now shorter.
		From *int64 `json:"from"`
	}
	if err := decode(raw, &a); err != nil {
		return err
	}
	if a.Lines <= 0 || a.Lines > 100000 {
		a.Lines = 2000
	}
	rel, err := cleanRel(a.Path)
	if err != nil {
		return err
	}
	root, err := s.openRoot(a.Root)
	if err != nil {
		return err
	}
	defer root.Close()
	f, err := root.Open(rel)
	if err != nil {
		return fsErr(err)
	}
	defer func() { f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return fsErr(err)
	}
	if !fi.Mode().IsRegular() {
		return wire.Errf(wire.CodeBadRequest, "只能跟踪普通文件")
	}
	start := lastLinesStart(f, fi.Size(), a.Lines)
	if a.From != nil && *a.From >= 0 && *a.From <= fi.Size() && fi.Size()-*a.From <= tailFirstMax {
		start = *a.From
	}
	if err := wire.WriteJSON(st, wire.OKResponse(map[string]any{"size": fi.Size(), "start": start, "name": fi.Name()})); err != nil {
		return nil
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { // the client closed the stream
		_, _ = io.Copy(io.Discard, st)
		cancel()
	}()
	pos := start
	send := func(to int64) bool {
		buf := make([]byte, wire.DataChunk)
		for pos < to {
			n := min(to-pos, int64(len(buf)))
			got, err := f.ReadAt(buf[:n], pos)
			if got > 0 {
				if wire.WriteFrame(st, wire.TypeData, buf[:got]) != nil {
					return false
				}
				pos += int64(got)
			}
			if err != nil {
				return true
			}
		}
		return true
	}
	note := func(kind string, extra map[string]any) bool {
		m := map[string]any{"type": kind}
		for k, v := range extra {
			m[k] = v
		}
		b, _ := json.Marshal(m)
		return wire.WriteFrame(st, wire.TypeJSON, b) == nil
	}
	if !send(fi.Size()) {
		return nil
	}
	ino := inode(fi)
	t := time.NewTicker(400 * time.Millisecond)
	defer t.Stop()
	quiet := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
		// replaced (rotated)? the path now names another file
		if nfi, err := root.Stat(rel); err == nil && inode(nfi) != ino {
			if nf, err := root.Open(rel); err == nil {
				if ofi, err := f.Stat(); err == nil {
					send(ofi.Size()) // what the old file got before it was moved away
				}
				f.Close()
				f, ino, pos = nf, inode(nfi), 0
				if !note("rotated", nil) {
					return nil
				}
			}
		}
		cur, err := f.Stat()
		if err != nil {
			continue
		}
		size := cur.Size()
		switch {
		case size < pos:
			pos = 0
			if !note("truncated", nil) {
				return nil
			}
		case size-pos > tailBehind:
			skipped := size - tailFirstMax - pos
			pos = size - tailFirstMax
			if !note("skipped", map[string]any{"bytes": skipped}) {
				return nil
			}
		}
		if size > pos {
			quiet = 0
			if !send(size) {
				return nil
			}
		} else if quiet++; quiet%75 == 0 { // ~30 s of silence: prove the stream is alive
			if !note("idle", nil) {
				return nil
			}
		}
	}
}

func inode(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

// lastLinesStart: offset of the last n lines, at most tailFirstMax back.
func lastLinesStart(f io.ReaderAt, size int64, n int) int64 {
	floor := max(size-tailFirstMax, 0)
	pos := size
	count := 0
	buf := make([]byte, 64<<10)
	for pos > floor {
		from := max(pos-int64(len(buf)), floor)
		chunk := buf[:pos-from]
		if _, err := f.ReadAt(chunk, from); err != nil && err != io.EOF {
			return floor
		}
		for i := len(chunk) - 1; i >= 0; i-- {
			// a trailing newline ends the last line rather than starting one
			if chunk[i] == '\n' && from+int64(i) != size-1 {
				if count++; count >= n {
					return from + int64(i) + 1
				}
			}
		}
		pos = from
	}
	if floor > 0 { // start at a line boundary
		b := make([]byte, 4096)
		if k, _ := f.ReadAt(b, floor); k > 0 {
			if i := bytes.IndexByte(b[:k], '\n'); i >= 0 {
				return floor + int64(i) + 1
			}
		}
	}
	return floor
}