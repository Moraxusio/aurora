package files

import (
	"aurora3/internal/wire"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"runtime"
	"strconv"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

type winWatchItem struct {
	Root string `json:"root"`
	Path string `json:"path"`
}

type winWatchChange struct {
	self  bool
	names map[string]bool
}

type winDirWatch struct {
	item       winWatchItem
	handle     windows.Handle
	overlapped windows.Overlapped
	buffer     [16 * 1024]byte
	pin        runtime.Pinner
	info       fs.FileInfo
	stopping   bool
}

func (e *Env) openNativeWatch(port windows.Handle, key uintptr, item winWatchItem) (*winDirWatch, error) {
	root, err := e.openRoot(item.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	rel, err := cleanRel(item.Path)
	if err != nil {
		return nil, err
	}
	dir, err := root.Open(rel)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	fi, err := dir.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.IsDir() {
		return nil, syscall.ENOTDIR
	}
	// An empty NT relative name reopens this exact os.Root-confined directory.
	// ReOpenFile rejects directory handles; omitting synchronous NT options
	// creates the independent overlapped handle required by the IOCP.
	name, err := windows.NewNTUnicodeString("")
	if err != nil {
		return nil, err
	}
	attrs := windows.OBJECT_ATTRIBUTES{RootDirectory: windows.Handle(dir.Fd()), ObjectName: name}
	attrs.Length = uint32(unsafe.Sizeof(attrs))
	var handle windows.Handle
	err = windows.NtCreateFile(&handle, windows.FILE_LIST_DIRECTORY|windows.SYNCHRONIZE,
		&attrs, &windows.IO_STATUS_BLOCK{}, nil, 0,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		windows.FILE_OPEN, windows.FILE_DIRECTORY_FILE|windows.FILE_OPEN_FOR_BACKUP_INTENT, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("open overlapped directory: %w", err)
	}
	w := &winDirWatch{item: item, handle: handle, info: fi}
	if _, err := windows.CreateIoCompletionPort(w.handle, port, key, 0); err != nil {
		windows.CloseHandle(w.handle)
		return nil, fmt.Errorf("attach completion port: %w", err)
	}
	w.pin.Pin(&w.overlapped)
	w.pin.Pin(&w.buffer[0])
	if err := w.arm(); err != nil {
		w.release()
		return nil, fmt.Errorf("read directory changes: %w", err)
	}
	return w, nil
}

func (w *winDirWatch) arm() error {
	w.overlapped = windows.Overlapped{}
	err := windows.ReadDirectoryChanges(w.handle, &w.buffer[0], uint32(len(w.buffer)), false,
		windows.FILE_NOTIFY_CHANGE_FILE_NAME|windows.FILE_NOTIFY_CHANGE_DIR_NAME|
			windows.FILE_NOTIFY_CHANGE_LAST_WRITE|windows.FILE_NOTIFY_CHANGE_SIZE|
			windows.FILE_NOTIFY_CHANGE_ATTRIBUTES, nil, &w.overlapped, 0)
	if errors.Is(err, windows.ERROR_IO_PENDING) {
		return nil
	}
	return err
}

func (w *winDirWatch) stop() {
	w.stopping = true
	_ = windows.CancelIoEx(w.handle, &w.overlapped)
}

func (w *winDirWatch) release() {
	_ = windows.CloseHandle(w.handle)
	w.pin.Unpin()
}

func nativeWatchNames(data []byte) ([]string, bool) {
	var names []string
	for offset := 0; ; {
		if offset+12 > len(data) {
			return nil, false
		}
		next := int(binary.LittleEndian.Uint32(data[offset:]))
		length := int(binary.LittleEndian.Uint32(data[offset+8:]))
		if length%2 != 0 || offset+12+length > len(data) {
			return nil, false
		}
		units := make([]uint16, length/2)
		for i := range units {
			units[i] = binary.LittleEndian.Uint16(data[offset+12+i*2:])
		}
		names = append(names, string(utf16.Decode(units)))
		if next == 0 {
			return names, true
		}
		if next < 12+length || next%4 != 0 {
			return nil, false
		}
		offset += next
	}
}

// One completion-port worker handles up to 512 directories (8 MiB of fixed
// buffers). Native events replace repeated stat scans. Unsupported/missing
// directories use a bounded two-second fallback and retry native subscription.
func (e *Env) fsWatch(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	defer st.Close()
	port, err := windows.CreateIoCompletionPort(windows.InvalidHandle, 0, 0, 1)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(port)
	if err := wire.WriteJSON(st, wire.Response{OK: true}); err != nil {
		return err
	}
	updates := make(chan []winWatchItem, 1)
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(cctx, func() {
		_ = st.Close()
		_ = windows.PostQueuedCompletionStatus(port, 0, 0, nil)
	})
	defer stop()
	go func() {
		defer cancel()
		for {
			var ctl struct {
				Type  string         `json:"type"`
				Items []winWatchItem `json:"items"`
			}
			if wire.ReadJSON(st, &ctl) != nil {
				return
			}
			if ctl.Type == "set" {
				if len(ctl.Items) > 512 {
					ctl.Items = ctl.Items[:512]
				}
				select {
				case <-updates:
				default:
				}
				select {
				case updates <- ctl.Items:
				case <-cctx.Done():
					return
				}
				_ = windows.PostQueuedCompletionStatus(port, 0, 0, nil)
			}
		}
	}()
	active := map[winWatchItem]uintptr{}
	pending := map[uintptr]*winDirWatch{}
	fallback := map[winWatchItem]string{}
	dirty := map[winWatchItem]*winWatchChange{}
	mark := func(it winWatchItem, names []string) {
		change := dirty[it]
		if change == nil {
			change = &winWatchChange{names: map[string]bool{}}
			dirty[it] = change
		}
		if names == nil {
			change.self = true
			clear(change.names)
		}
		if change.self {
			return
		}
		for _, name := range names {
			change.names[name] = true
		}
		if len(change.names) > 512 {
			change.self = true
			clear(change.names)
		}
	}
	var key uintptr
	defer func() {
		for _, w := range pending {
			w.stop()
		}
		// CancelIoEx completes asynchronously. Never unpin an OVERLAPPED or
		// notification buffer until Windows has delivered its completion.
		for len(pending) > 0 {
			var n uint32
			var id uintptr
			var overlapped *windows.Overlapped
			_ = windows.GetQueuedCompletionStatus(port, &n, &id, &overlapped, windows.INFINITE)
			if w := pending[id]; w != nil && overlapped != nil {
				w.release()
				delete(pending, id)
			}
		}
	}()
	add := func(it winWatchItem) bool {
		if len(pending) >= 512 {
			return false
		}
		key++
		w, err := e.openNativeWatch(port, key, it)
		if err != nil {
			return false
		}
		active[it], pending[key] = key, w
		return true
	}
	lastFallback, lastFlush := time.Now(), time.Now()
	lastStatus := ""
	for {
		if cctx.Err() != nil {
			return nil
		}
		select {
		case items := <-updates:
			wanted := map[winWatchItem]bool{}
			for _, it := range items {
				wanted[it] = true
			}
			for it, id := range active {
				if !wanted[it] {
					pending[id].stop()
					delete(active, it)
				}
			}
			for it := range fallback {
				if !wanted[it] {
					delete(fallback, it)
				}
			}
			for it := range dirty {
				if !wanted[it] {
					delete(dirty, it)
				}
			}
			for it := range wanted {
				if _, ok := active[it]; ok {
					continue
				}
				if _, ok := fallback[it]; ok {
					continue
				}
				if !add(it) {
					fallback[it] = ""
				}
				mark(it, nil)
			}
		default:
		}
		if time.Since(lastFallback) >= 2*time.Second {
			lastFallback = time.Now()
			// A directory handle follows a rename. Check only directory identity
			// (not its children) so a recreated subscribed path gets a new watch.
			for it, id := range active {
				root, err := e.openRoot(it.Root)
				var info fs.FileInfo
				if err == nil {
					rel, cleanErr := cleanRel(it.Path)
					if cleanErr == nil {
						info, err = root.Stat(rel)
					} else {
						err = cleanErr
					}
					root.Close()
				}
				if err != nil || info == nil || !os.SameFile(info, pending[id].info) {
					pending[id].stop()
					delete(active, it)
					fallback[it] = ""
					mark(it, nil)
				}
			}
			for it, previous := range fallback {
				if add(it) {
					delete(fallback, it)
					mark(it, nil)
					continue
				}
				root, err := e.openRoot(it.Root)
				if err != nil {
					continue
				}
				rel, err := cleanRel(it.Path)
				if err != nil {
					root.Close()
					continue
				}
				d, err := root.Open(rel)
				signature := "missing"
				if err == nil {
					entries, err := d.ReadDir(maxListEntries + 1)
					d.Close()
					if err == nil {
						signature = watchSignature(entries)
					}
				}
				root.Close()
				if previous != signature {
					mark(it, nil)
				}
				fallback[it] = signature
			}
		}
		if time.Since(lastFlush) >= 75*time.Millisecond {
			lastFlush = time.Now()
			status := strconv.Itoa(len(active)) + "/" + strconv.Itoa(len(fallback))
			if status != lastStatus {
				lastStatus = status
				_ = st.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := wire.WriteJSON(st, map[string]any{"type": "status", "native": len(active),
					"fallback": len(fallback), "limit": maxListEntries}); err != nil {
					return err
				}
			}
			for it, change := range dirty {
				_ = st.SetWriteDeadline(time.Now().Add(10 * time.Second))
				names := make([]string, 0, len(change.names))
				for name := range change.names {
					names = append(names, name)
				}
				if err := wire.WriteJSON(st, map[string]any{"type": "change", "root": it.Root,
					"path": it.Path, "self": change.self, "names": names, "native": active[it] != 0}); err != nil {
					return err
				}
			}
			clear(dirty)
		}
		var n uint32
		var id uintptr
		var overlapped *windows.Overlapped
		err := windows.GetQueuedCompletionStatus(port, &n, &id, &overlapped, 75)
		w := pending[id]
		if w == nil || overlapped == nil {
			continue
		}
		if w.stopping {
			w.release()
			delete(pending, id)
			continue
		}
		if err != nil {
			mark(w.item, nil)
			delete(active, w.item)
			fallback[w.item] = ""
			w.release()
			delete(pending, id)
			continue
		}
		// Zero bytes means the kernel buffer overflowed; force a full refresh.
		names, valid := nativeWatchNames(w.buffer[:min(n, uint32(len(w.buffer)))])
		mark(w.item, names)
		if n == 0 || !valid {
			_ = st.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := wire.WriteJSON(st, map[string]any{"type": "overflow"}); err != nil {
				// This completion has already been consumed; cleanup must not
				// wait for an IO that was never re-armed.
				w.release()
				delete(pending, id)
				return err
			}
		}
		if err := w.arm(); err != nil {
			delete(active, w.item)
			fallback[w.item] = ""
			w.release()
			delete(pending, id)
		}
	}
}

// Stream the same metadata into a fixed-size digest. Repeated string
// concatenation copied O(N²) bytes on every 800 ms poll of a large folder.
func watchSignature(entries []fs.DirEntry) string {
	h := sha256.New()
	buf := make([]byte, 0, 256)
	for _, ent := range entries {
		fi, err := ent.Info()
		if err != nil {
			continue
		}
		buf = append(buf[:0], ent.Name()...)
		buf = append(buf, ':')
		buf = strconv.AppendInt(buf, fi.Size(), 10)
		buf = append(buf, ':')
		buf = strconv.AppendInt(buf, fi.ModTime().UnixNano(), 10)
		buf = append(buf, ';')
		_, _ = h.Write(buf)
	}
	return string(h.Sum(nil))
}
