//go:build linux

package files

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"aurora3/internal/wire"
)

// fs.watch tells the client when folders it shows change on the server, so the
// explorer and open editors stay current without polling.
//
//	client -> agent  {"type":"set","items":[{"root":"home","path":"/src"}]}
//	agent -> client  {"type":"change","root":"home","path":"/src","names":["a.py"]}
//	                 {"type":"change","root":"home","path":"/src","self":true}  folder removed or moved
//	                 {"type":"overflow"}  the kernel dropped events: refresh everything
//
// Only directories are watched; an open file is covered by its parent folder.
// inotify does not see changes made on other machines of a network filesystem.

const (
	maxWatchDirs = 512
	watchFlush   = 300 * time.Millisecond
	watchMask    = syscall.IN_CREATE | syscall.IN_DELETE | syscall.IN_MOVED_FROM | syscall.IN_MOVED_TO |
		syscall.IN_CLOSE_WRITE | syscall.IN_MODIFY | syscall.IN_ATTRIB | syscall.IN_DELETE_SELF | syscall.IN_MOVE_SELF | syscall.IN_ONLYDIR
)

type watchItem struct {
	Root string `json:"root"`
	Path string `json:"path"`
}

type watchCtl struct {
	Type  string      `json:"type"`
	Items []watchItem `json:"items"`
}

type watchEvent struct {
	Type  string   `json:"type"`
	Root  string   `json:"root,omitempty"`
	Path  string   `json:"path,omitempty"`
	Names []string `json:"names,omitempty"`
	Self  bool     `json:"self,omitempty"`
}

// watchDir resolves a client folder to a real directory inside its root.
func (s *Env) watchDir(it watchItem) (string, bool) {
	var rootDir string
	for _, r := range s.Roots {
		if r.ID == it.Root {
			rootDir = r.Path
		}
	}
	if rootDir == "" {
		return "", false
	}
	rel, err := cleanRel(it.Path)
	if err != nil {
		return "", false
	}
	realRoot, err := filepath.EvalSymlinks(rootDir)
	if err != nil {
		return "", false
	}
	real, err := filepath.EvalSymlinks(filepath.Join(rootDir, rel))
	if err != nil {
		return "", false
	}
	if realRoot != "/" && real != realRoot && !strings.HasPrefix(real, realRoot+"/") {
		return "", false
	}
	if fi, err := os.Stat(real); err != nil || !fi.IsDir() {
		return "", false
	}
	return real, true
}

type watcher struct {
	s    *Env
	fd   int
	f    *os.File
	mu   sync.Mutex
	byWD map[int32][]watchItem // one directory can back several client paths
	wdOf map[watchItem]int32
	// pending changes per watch descriptor, flushed every watchFlush
	names    map[int32]map[string]bool
	self     []watchItem // folders that were removed or moved away
	overflow bool
}

func (s *Env) fsWatch(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	fd, err := syscall.InotifyInit1(syscall.IN_CLOEXEC | syscall.IN_NONBLOCK)
	if err != nil {
		return wire.Errf(wire.CodeUnavailable, "无法监听文件变化：%v", err)
	}
	w := &watcher{s: s, fd: fd, f: os.NewFile(uintptr(fd), "inotify"), byWD: map[int32][]watchItem{}, wdOf: map[watchItem]int32{},
		names: map[int32]map[string]bool{}}
	defer w.f.Close()
	var wmu sync.Mutex
	send := func(v any) error {
		wmu.Lock()
		defer wmu.Unlock()
		_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
		return wire.WriteJSON(st, v)
	}
	if err := send(wire.Response{OK: true}); err != nil {
		return nil
	}
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { // client -> agent: subscription updates
		defer cancel()
		for {
			typ, p, err := wire.ReadFrame(st)
			if err != nil {
				return
			}
			if typ != wire.TypeJSON {
				continue
			}
			var c watchCtl
			if json.Unmarshal(p, &c) == nil && c.Type == "set" {
				w.set(c.Items)
			}
		}
	}()
	go w.read(cctx)
	t := time.NewTicker(watchFlush)
	defer t.Stop()
	for {
		select {
		case <-cctx.Done():
			return nil
		case <-t.C:
			for _, ev := range w.drain() {
				if send(ev) != nil {
					return nil
				}
			}
		}
	}
}

// set replaces the watched folders with items.
func (w *watcher) set(items []watchItem) {
	if len(items) > maxWatchDirs {
		items = items[:maxWatchDirs]
	}
	want := map[watchItem]string{}
	for _, it := range items {
		it.Path = "/" + strings.Trim(path.Clean("/"+it.Path), "/")
		if dir, ok := w.s.watchDir(it); ok {
			want[it] = dir
		}
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for it, wd := range w.wdOf {
		if _, keep := want[it]; keep {
			continue
		}
		delete(w.wdOf, it)
		w.byWD[wd] = without(w.byWD[wd], it)
		if len(w.byWD[wd]) == 0 {
			delete(w.byWD, wd)
			_, _ = syscall.InotifyRmWatch(w.fd, uint32(wd))
		}
	}
	for it, dir := range want {
		if _, have := w.wdOf[it]; have {
			continue
		}
		wd, err := syscall.InotifyAddWatch(w.fd, dir, watchMask)
		if err != nil {
			continue // e.g. the per-user watch limit; the folder just is not live
		}
		w.wdOf[it] = int32(wd)
		w.byWD[int32(wd)] = append(w.byWD[int32(wd)], it)
	}
}

func without(list []watchItem, it watchItem) []watchItem {
	out := list[:0]
	for _, x := range list {
		if x != it {
			out = append(out, x)
		}
	}
	return out
}

// read collects kernel events until the descriptor is closed.
func (w *watcher) read(ctx context.Context) {
	go func() { <-ctx.Done(); w.f.Close() }()
	buf := make([]byte, 64*1024)
	for {
		n, err := w.f.Read(buf)
		if err != nil {
			return
		}
		w.parse(buf[:n])
	}
}

func (w *watcher) parse(b []byte) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for len(b) >= syscall.SizeofInotifyEvent {
		wd := int32(binary.NativeEndian.Uint32(b[0:4]))
		mask := binary.NativeEndian.Uint32(b[4:8])
		nlen := int(binary.NativeEndian.Uint32(b[12:16]))
		end := syscall.SizeofInotifyEvent + nlen
		if end > len(b) {
			return
		}
		name := strings.TrimRight(string(b[syscall.SizeofInotifyEvent:end]), "\x00")
		b = b[end:]
		switch {
		case mask&syscall.IN_Q_OVERFLOW != 0:
			w.overflow = true
		case mask&syscall.IN_IGNORED != 0:
			for _, it := range w.byWD[wd] {
				delete(w.wdOf, it)
			}
			delete(w.byWD, wd)
		case mask&(syscall.IN_DELETE_SELF|syscall.IN_MOVE_SELF) != 0:
			// Capture the folders now: IN_IGNORED follows and drops the mapping.
			w.self = append(w.self, w.byWD[wd]...)
		case name != "" && !strings.HasPrefix(name, partPrefix):
			if w.names[wd] == nil {
				w.names[wd] = map[string]bool{}
			}
			if len(w.names[wd]) < 200 {
				w.names[wd][name] = true
			}
		}
	}
}

// drain turns the pending changes into events, one per client folder.
func (w *watcher) drain() []watchEvent {
	w.mu.Lock()
	defer w.mu.Unlock()
	var out []watchEvent
	if w.overflow {
		w.overflow = false
		w.names = map[int32]map[string]bool{}
		w.self = nil
		return []watchEvent{{Type: "overflow"}}
	}
	for wd, set := range w.names {
		names := make([]string, 0, len(set))
		for n := range set {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, it := range w.byWD[wd] {
			out = append(out, watchEvent{Type: "change", Root: it.Root, Path: it.Path, Names: names})
		}
	}
	for _, it := range w.self {
		out = append(out, watchEvent{Type: "change", Root: it.Root, Path: it.Path, Self: true})
	}
	w.names = map[int32]map[string]bool{}
	w.self = nil
	return out
}