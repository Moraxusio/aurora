//go:build linux

package files

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"aurora3/internal/wire"
)

const (
	maxListEntries = 5000
	maxInlineBytes = 512 * 1024 // fs.read / fs.write payloads travel in one frame
	partPrefix     = ".aurora-upload-"
)

type rootInfo struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
	OK    bool   `json:"ok"`
	Total uint64 `json:"total,omitempty"`
	Free  uint64 `json:"free,omitempty"`
}

func (s *Env) rootsInfo() []rootInfo {
	out := make([]rootInfo, 0, len(s.Roots))
	for _, r := range s.Roots {
		ri := rootInfo{ID: r.ID, Label: r.Label, Path: r.Path}
		if st, ok := statfsBounded(r.Path); ok {
			ri.OK = true
			ri.Total = st.Blocks * uint64(st.Bsize)
			ri.Free = st.Bavail * uint64(st.Bsize)
		}
		out = append(out, ri)
	}
	return out
}

// statfsBounded stats a root without letting a hung mount (a dead NFS
// server) pile up stuck threads: it waits at most 2 s, and while one call
// on a path is still stuck no other is started for it. Every stuck syscall
// pins an OS thread, and Go aborts the process at 10000 threads.
var mountInfoReader = func() ([]string, error) {
	b, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil, err
	}
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.SplitN(line, " - ", 2)
		if len(f) == 0 {
			continue
		}
		fields := strings.Fields(f[0])
		if len(fields) >= 5 {
			out = append(out, strings.ReplaceAll(fields[4], "\\040", " "))
		}
	}
	return out, nil
}

var (
	statfsBusy  sync.Map // mount point -> *statfsCall
	statfsSlots = make(chan struct{}, 4)
	mountMu     sync.Mutex
	mountAt     time.Time
	mounts      []string
	statfsProbe = func(p string, st *syscall.Statfs_t) bool {
		fi, err := os.Stat(p)
		return err == nil && fi.IsDir() && syscall.Statfs(p, st) == nil
	}
)

func statfsMount(p string) string {
	mountMu.Lock()
	defer mountMu.Unlock()
	if time.Since(mountAt) > 10*time.Second || mounts == nil {
		mounts = mounts[:0]
		if ms, err := mountInfoReader(); err == nil {
			mounts = append(mounts, ms...)
		}
		mountAt = time.Now()
	}
	best := "/"
	for _, m := range mounts {
		if (p == m || strings.HasPrefix(p, strings.TrimSuffix(m, "/")+"/")) && len(m) > len(best) {
			best = m
		}
	}
	return best
}

// statfsCall is one statfs in flight; callers that arrive meanwhile wait for
// its answer instead of reporting the drive as unavailable.
type statfsCall struct {
	done chan struct{}
	st   syscall.Statfs_t
	ok   bool
}

func statfsBounded(p string) (syscall.Statfs_t, bool) {
	key := statfsMount(filepath.Clean(p))
	c := &statfsCall{done: make(chan struct{})}
	if v, busy := statfsBusy.LoadOrStore(key, c); busy {
		c = v.(*statfsCall)
	} else {
		select {
		case statfsSlots <- struct{}{}:
		default:
			statfsBusy.Delete(key)
			return syscall.Statfs_t{}, false
		}
		go func() {
			defer statfsBusy.Delete(key)
			defer func() { <-statfsSlots }()
			c.ok = statfsProbe(p, &c.st)
			close(c.done)
		}()
	}
	select {
	case <-c.done:
		return c.st, c.ok
	case <-time.After(2 * time.Second):
		return syscall.Statfs_t{}, false
	}
}

// cleanRel validates a client path ("/a/b") and returns it relative to the
// root ("a/b", or "." for the root itself).
func cleanRel(p string) (string, error) {
	if len(p) > 4096 || strings.ContainsAny(p, "\x00\\") {
		return "", wire.Errf(wire.CodeBadRequest, "路径无效")
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".." {
			return "", wire.Errf(wire.CodeForbidden, "不允许访问根目录以外的路径")
		}
	}
	rel := strings.TrimPrefix(path.Clean("/"+p), "/")
	if rel == "" {
		rel = "."
	}
	return rel, nil
}

// openRoot returns a traversal-safe handle: os.Root refuses any path (or
// symlink) that resolves outside the configured root directory.
func (s *Env) openRoot(id string) (*os.Root, error) {
	for _, r := range s.Roots {
		if r.ID == id || (id == "" && len(s.Roots) > 0 && r.ID == s.Roots[0].ID) {
			root, err := os.OpenRoot(r.Path)
			if err != nil {
				return nil, wire.Errf(wire.CodeUnavailable, "根目录不可用：%s", r.Label)
			}
			return root, nil
		}
	}
	return nil, wire.Errf(wire.CodeNotFound, "未知的根目录：%s", id)
}

func fsErr(err error) error {
	var oe *wire.OpError
	switch {
	case err == nil:
		return nil
	case errors.As(err, &oe):
		return err
	case errors.Is(err, fs.ErrNotExist):
		return wire.Errf(wire.CodeNotFound, "文件或目录不存在")
	// ENOTEMPTY must come before ErrExist: Go counts it as "exists" too.
	case errors.Is(err, syscall.ENOTEMPTY):
		return wire.Errf(wire.CodeConflict, "目录不为空")
	case errors.Is(err, fs.ErrExist):
		return wire.Errf(wire.CodeConflict, "已存在同名文件或目录")
	case errors.Is(err, fs.ErrPermission):
		return wire.Errf(wire.CodeForbidden, "没有权限")
	case errors.Is(err, syscall.ENOSPC):
		return wire.Errf(wire.CodeConflict, "磁盘空间不足")
	case strings.Contains(err.Error(), "path escapes"):
		return wire.Errf(wire.CodeForbidden, "不允许访问根目录以外的路径")
	}
	return wire.Errf(wire.CodeInternal, "%v", err)
}

type entry struct {
	Name   string `json:"name"`
	Type   string `json:"type"` // dir | file | link | other
	Size   int64  `json:"size"`
	Mtime  int64  `json:"mtime"` // unix ms
	Mode   string `json:"mode"`
	Target string `json:"target,omitempty"` // links: dir | file | broken | outside
	// LinkRoot/LinkPath locate a symlink's destination inside a configured root,
	// so the client can open it there (os.Root refuses absolute link targets).
	LinkRoot string `json:"link_root,omitempty"`
	LinkPath string `json:"link_path,omitempty"`
	Etag     string `json:"etag,omitempty"`
	Owner    string `json:"owner,omitempty"`
	Group    string `json:"group,omitempty"`
}

func etag(fi fs.FileInfo) string {
	var ino, ctime int64
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		ino = int64(st.Ino)
		ctime = st.Ctim.Sec*1e9 + st.Ctim.Nsec
	}
	return fmt.Sprintf("%x-%x-%x-%x", fi.ModTime().UnixNano(), fi.Size(), ino, ctime)
}

func (s *Env) toEntry(root *os.Root, rootDir, rel string, fi fs.FileInfo) entry {
	e := entry{Name: fi.Name(), Size: fi.Size(), Mtime: fi.ModTime().UnixMilli(), Mode: fi.Mode().String()}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		e.Owner, e.Group = idNames.user(st.Uid), idNames.group(st.Gid)
	}
	switch {
	case fi.IsDir():
		e.Type = "dir"
	case fi.Mode()&fs.ModeSymlink != 0:
		e.Type = "link"
		e.Target = "broken"
		resolved, err := filepath.EvalSymlinks(filepath.Join(rootDir, rel))
		if err != nil {
			break
		}
		t, err := os.Stat(resolved)
		if err != nil {
			break
		}
		kind := "file"
		if t.IsDir() {
			kind = "dir"
		}
		e.Target = "outside"
		best := -1
		for _, r := range s.Roots {
			if (resolved == r.Path || strings.HasPrefix(resolved, strings.TrimSuffix(r.Path, "/")+"/")) && len(r.Path) > best {
				best = len(r.Path)
				e.LinkRoot = r.ID
				e.LinkPath = "/" + strings.TrimPrefix(strings.TrimPrefix(resolved, r.Path), "/")
			}
		}
		if best >= 0 {
			e.Target = kind
		}
	case fi.Mode().IsRegular():
		e.Type = "file"
		e.Etag = etag(fi)
	default:
		e.Type = "other"
	}
	return e
}

type fsArgs struct {
	Root      string `json:"root"`
	Path      string `json:"path"`
	To        string `json:"to"`
	Hidden    bool   `json:"hidden"`
	Recursive bool   `json:"recursive"`
	Content   string `json:"content"`
	IfMatch   string `json:"if_match"`
	Create    bool   `json:"create"` // fail if the file already exists
	Size      int64  `json:"size"`
	Offset    int64  `json:"offset"`
	Length    int64  `json:"length"` // fs.download: at most this many bytes (0: to the end)
}

func (s *Env) fsPrep(raw json.RawMessage) (*fsArgs, *os.Root, string, error) {
	a, root, rel, _, err := s.fsPrepDir(raw)
	return a, root, rel, err
}

func (s *Env) fsPrepDir(raw json.RawMessage) (*fsArgs, *os.Root, string, string, error) {
	var a fsArgs
	if err := decode(raw, &a); err != nil {
		return nil, nil, "", "", err
	}
	rel, err := cleanRel(a.Path)
	if err != nil {
		return nil, nil, "", "", err
	}
	root, err := s.openRoot(a.Root)
	if err != nil {
		return nil, nil, "", "", err
	}
	return &a, root, rel, rootPath(s, a.Root), nil
}

func (s *Env) fsList(ctx context.Context, raw json.RawMessage) (any, error) {
	_, root, rel, rootDir, err := s.fsPrepDir(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	d, err := root.Open(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	defer d.Close()
	if fi, err := d.Stat(); err != nil || !fi.IsDir() {
		return nil, wire.Errf(wire.CodeBadRequest, "不是目录")
	}
	des, err := d.ReadDir(maxListEntries + 1)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, fsErr(err)
	}
	truncated := len(des) > maxListEntries
	if truncated {
		des = des[:maxListEntries]
	}
	out := make([]entry, 0, len(des))
	for _, de := range des {
		name := de.Name()
		if strings.HasPrefix(name, partPrefix) {
			continue
		}
		fi, err := de.Info()
		if err != nil {
			continue
		}
		out = append(out, s.toEntry(root, rootDir, path.Join(rel, name), fi))
	}
	sort.Slice(out, func(i, j int) bool {
		di, dj := out[i].Type == "dir" || out[i].Target == "dir", out[j].Type == "dir" || out[j].Target == "dir"
		if di != dj {
			return di
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return map[string]any{"path": "/" + strings.TrimPrefix(rel, "."), "entries": out, "truncated": truncated}, nil
}

func (s *Env) fsStat(ctx context.Context, raw json.RawMessage) (any, error) {
	_, root, rel, rootDir, err := s.fsPrepDir(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	fi, err := root.Lstat(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	return s.toEntry(root, rootDir, rel, fi), nil
}

func looksBinary(b []byte) bool {
	n := min(len(b), 8192)
	for _, c := range b[:n] {
		if c == 0 {
			return true
		}
	}
	// allow a multi-byte rune cut at the inline limit
	for i := 0; i < 4 && len(b) > 0 && !utf8.Valid(b); i++ {
		b = b[:len(b)-1]
	}
	return !utf8.Valid(b)
}

func (s *Env) fsRead(ctx context.Context, raw json.RawMessage) (any, error) {
	_, root, rel, err := s.fsPrep(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	f, err := root.Open(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, fsErr(err)
	}
	if !fi.Mode().IsRegular() {
		return nil, wire.Errf(wire.CodeBadRequest, "不是普通文件")
	}
	// "tail" reads the end of a file too big to send whole: what matters in a
	// growing log is the newest part. The window starts after a line break
	// so the first line shown is complete.
	var opt struct {
		Tail bool `json:"tail"`
	}
	_ = json.Unmarshal(raw, &opt)
	var start int64
	if opt.Tail && fi.Size() > maxInlineBytes {
		start = fi.Size() - maxInlineBytes
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			return nil, fsErr(err)
		}
	}
	buf := make([]byte, maxInlineBytes)
	n, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil, fsErr(err)
	}
	buf = buf[:n]
	if start > 0 {
		if i := bytes.IndexByte(buf, '\n'); i >= 0 && i < len(buf)-1 {
			start += int64(i + 1)
			buf = buf[i+1:]
		}
	}
	res := map[string]any{"size": fi.Size(), "mtime": fi.ModTime().UnixMilli(), "etag": etag(fi), "truncated": fi.Size() > int64(n)}
	if start > 0 {
		res["tail"] = true
		res["offset"] = start
	}
	if looksBinary(buf) {
		res["binary"] = true
		return res, nil
	}
	res["content"] = strings.ToValidUTF8(string(buf), "\uFFFD")
	return res, nil
}

// writeAtomic writes data next to the target and renames it into place, so a
// crash or full disk never leaves a half-written file.
func writeAtomic(root *os.Root, rel string, r io.Reader, mode fs.FileMode) (int64, error) {
	dir, base := path.Split(rel)
	tmp := path.Join(dir, partPrefix+wire.NewToken()[:12]+"-"+base+".part")
	f, err := root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return 0, err
	}
	// The agent runs as root; the file keeps the owner it had, or gets the
	// owner of its folder, so a save never hands someone's file to root.
	if uid, gid, ok := ownerFor(root, rel); ok {
		_ = f.Chown(uid, gid)
	}
	n, err := io.Copy(f, r)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = root.Rename(tmp, rel)
	}
	if err != nil {
		_ = root.Remove(tmp)
		return n, err
	}
	return n, nil
}

// ownerFor is who a file written at rel should belong to: its current owner
// when it exists, otherwise the owner of the folder it goes into. ok is false
// when the agent is not root (it cannot give files away then anyway).
func ownerFor(root *os.Root, rel string) (uid, gid int, ok bool) {
	if os.Geteuid() != 0 {
		return 0, 0, false
	}
	fi, err := root.Lstat(rel)
	if err != nil {
		fi, err = root.Stat(path.Dir(rel))
	}
	if err != nil {
		return 0, 0, false
	}
	st, isStat := fi.Sys().(*syscall.Stat_t)
	if !isStat {
		return 0, 0, false
	}
	return int(st.Uid), int(st.Gid), true
}

func checkTarget(root *os.Root, rel string, a *fsArgs) (fs.FileMode, error) {
	if rel == "." {
		return 0, wire.Errf(wire.CodeBadRequest, "不能写入根目录本身")
	}
	mode := fs.FileMode(0o644)
	fi, err := root.Stat(rel)
	switch {
	case err == nil:
		if !fi.Mode().IsRegular() {
			return 0, wire.Errf(wire.CodeConflict, "目标不是普通文件")
		}
		if a.Create {
			return 0, wire.Errf(wire.CodeConflict, "已存在同名文件")
		}
		if a.IfMatch != "" && a.IfMatch != etag(fi) {
			return 0, wire.Errf(wire.CodeConflict, "文件已被其他程序修改，请重新打开后再保存")
		}
		mode = fi.Mode().Perm()
	case errors.Is(err, fs.ErrNotExist):
		if a.IfMatch != "" {
			return 0, wire.Errf(wire.CodeConflict, "文件已被删除")
		}
		if pfi, perr := root.Stat(path.Dir(rel)); perr != nil || !pfi.IsDir() {
			return 0, wire.Errf(wire.CodeNotFound, "上级目录不存在")
		}
	default:
		return 0, fsErr(err)
	}
	return mode, nil
}

func (s *Env) fsWrite(ctx context.Context, raw json.RawMessage) (any, error) {
	a, root, rel, rootDir, err := s.fsPrepDir(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if len(a.Content) > maxInlineBytes {
		return nil, wire.Errf(wire.CodeBadRequest, "内容过大，请使用上传")
	}
	mode, err := checkTarget(root, rel, a)
	if err != nil {
		return nil, err
	}
	if _, err := writeAtomic(root, rel, strings.NewReader(a.Content), mode); err != nil {
		return nil, fsErr(err)
	}
	s.Audit.Write("fs.write", map[string]any{"root": a.Root, "path": rel, "bytes": len(a.Content)})
	fi, err := root.Lstat(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	return s.toEntry(root, rootDir, rel, fi), nil
}

func validName(rel string) error {
	base := path.Base(rel)
	if rel == "." || base == "" || len(base) > 255 || strings.HasPrefix(base, partPrefix) {
		return wire.Errf(wire.CodeBadRequest, "名称无效")
	}
	return nil
}

func (s *Env) fsMkdir(ctx context.Context, raw json.RawMessage) (any, error) {
	a, root, rel, err := s.fsPrep(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if err := validName(rel); err != nil {
		return nil, err
	}
	if err := root.Mkdir(rel, 0o755); err != nil {
		return nil, fsErr(err)
	}
	if uid, gid, ok := ownerFor(root, path.Dir(rel)); ok {
		_ = root.Lchown(rel, uid, gid)
	}
	s.Audit.Write("fs.mkdir", map[string]any{"root": a.Root, "path": rel})
	return map[string]any{"path": "/" + rel}, nil
}

func (s *Env) fsRename(ctx context.Context, raw json.RawMessage) (any, error) {
	a, root, rel, err := s.fsPrep(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	to, err := cleanRel(a.To)
	if err != nil {
		return nil, err
	}
	if rel == "." || validName(to) != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "不能移动根目录或使用无效名称")
	}
	if to == rel || strings.HasPrefix(to+"/", rel+"/") {
		return nil, wire.Errf(wire.CodeBadRequest, "不能移动到自身或其子目录中")
	}
	if _, err := root.Lstat(to); err == nil {
		return nil, wire.Errf(wire.CodeConflict, "目标位置已存在同名文件或目录")
	}
	if pfi, err := root.Stat(path.Dir(to)); err != nil || !pfi.IsDir() {
		return nil, wire.Errf(wire.CodeNotFound, "目标目录不存在")
	}
	if err := root.Rename(rel, to); err != nil {
		return nil, fsErr(err)
	}
	s.Audit.Write("fs.rename", map[string]any{"root": a.Root, "from": rel, "to": to})
	return map[string]any{"path": "/" + to}, nil
}

// fsCopy copies a file, or a folder with everything in it, inside one root.
// Nothing is overwritten: a name already taken is a conflict.
func (s *Env) fsCopy(ctx context.Context, raw json.RawMessage) (any, error) {
	a, root, rel, err := s.fsPrep(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	to, err := cleanRel(a.To)
	if err != nil {
		return nil, err
	}
	if rel == "." || validName(to) != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "不能复制根目录或使用无效名称")
	}
	if to == rel || strings.HasPrefix(to+"/", rel+"/") {
		return nil, wire.Errf(wire.CodeBadRequest, "不能复制到自身或其子目录中")
	}
	src, err := root.Lstat(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	if _, err := root.Lstat(to); err == nil {
		return nil, wire.Errf(wire.CodeConflict, "目标位置已存在同名文件或目录")
	}
	if pfi, err := root.Stat(path.Dir(to)); err != nil || !pfi.IsDir() {
		return nil, wire.Errf(wire.CodeNotFound, "目标目录不存在")
	}
	if err := copyTree(ctx, root, rel, to, src); err != nil {
		_ = root.RemoveAll(to) // do not leave a half copy behind
		return nil, fsErr(err)
	}
	s.Audit.Write("fs.copy", map[string]any{"root": a.Root, "from": rel, "to": to})
	return map[string]any{"path": "/" + to}, nil
}

// copyTree copies src (described by fi) to dst inside root. Symbolic links are
// copied as links, not followed; special files are refused.
func copyTree(ctx context.Context, root *os.Root, src, dst string, fi fs.FileInfo) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	switch {
	case fi.Mode()&fs.ModeSymlink != 0:
		target, err := root.Readlink(src)
		if err != nil {
			return err
		}
		return root.Symlink(target, dst)
	case fi.IsDir():
		if err := root.Mkdir(dst, fi.Mode().Perm()); err != nil {
			return err
		}
		d, err := root.Open(src)
		if err != nil {
			return err
		}
		entries, err := d.ReadDir(-1)
		d.Close()
		if err != nil {
			return err
		}
		for _, e := range entries {
			child, err := root.Lstat(path.Join(src, e.Name()))
			if err != nil {
				return err
			}
			if err := copyTree(ctx, root, path.Join(src, e.Name()), path.Join(dst, e.Name()), child); err != nil {
				return err
			}
		}
		return nil
	case fi.Mode().IsRegular():
		in, err := root.Open(src)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := root.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, fi.Mode().Perm())
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, ctxReader{ctx, in}); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	default:
		return wire.Errf(wire.CodeBadRequest, "不能复制这种特殊文件")
	}
}

// ctxReader stops a long copy when the request is cancelled.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

func (s *Env) fsDelete(ctx context.Context, raw json.RawMessage) (any, error) {
	a, root, rel, err := s.fsPrep(raw)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if rel == "." {
		return nil, wire.Errf(wire.CodeForbidden, "不能删除根目录")
	}
	fi, err := root.Lstat(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	if fi.IsDir() && a.Recursive {
		err = root.RemoveAll(rel)
	} else {
		err = root.Remove(rel)
	}
	if err != nil {
		return nil, fsErr(err)
	}
	s.Audit.Write("fs.delete", map[string]any{"root": a.Root, "path": rel, "recursive": a.Recursive})
	return map[string]any{"deleted": "/" + rel}, nil
}

// frameReader turns 'D' frames into a byte stream until 'E'.
type frameReader struct {
	r    io.Reader
	buf  []byte
	done bool
	max  int64
	n    int64
}

func (f *frameReader) Read(p []byte) (int, error) {
	for len(f.buf) == 0 {
		if f.done {
			return 0, io.EOF
		}
		typ, payload, err := wire.ReadFrame(f.r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = io.ErrUnexpectedEOF // Only TypeEnd can commit an upload.
			}
			return 0, err
		}
		switch typ {
		case wire.TypeData:
			f.buf = payload
			f.n += int64(len(payload))
			if f.n > f.max {
				return 0, wire.Errf(wire.CodeBadRequest, "上传数据超过声明的大小")
			}
		case wire.TypeEnd:
			if f.n != f.max {
				return 0, wire.Errf(wire.CodeBadRequest, "上传不完整：收到 %d / %d 字节", f.n, f.max)
			}
			f.done = true
		default:
			return 0, wire.Errf(wire.CodeBadRequest, "上传帧类型错误")
		}
	}
	n := copy(p, f.buf)
	f.buf = f.buf[n:]
	return n, nil
}

func (s *Env) fsUpload(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	a, root, rel, rootDir, err := s.fsPrepDir(raw)
	if err != nil {
		return err
	}
	defer root.Close()
	if err := validName(rel); err != nil {
		return err
	}
	if a.Size < 0 || a.Size > s.UploadMaxBytes {
		return wire.Errf(wire.CodeBadRequest, "文件超过上传上限")
	}
	mode, err := checkTarget(root, rel, a)
	if err != nil {
		return err
	}
	if sfs, ok := statfsBounded(filepath.Join(rootPath(s, a.Root), path.Dir(rel))); ok {
		if free := int64(sfs.Bavail) * int64(sfs.Bsize); a.Size > free-64<<20 {
			return wire.Errf(wire.CodeConflict, "磁盘空间不足：需要 %d 字节，剩余 %d 字节", a.Size, free)
		}
	}
	if err := wire.WriteJSON(st, wire.Response{OK: true}); err != nil {
		return nil
	}
	start := time.Now()
	fr := &frameReader{r: st, max: a.Size}
	n, err := writeAtomic(root, rel, fr, mode)
	if err != nil {
		if errors.Is(err, syscall.ENOSPC) {
			return wire.Errf(wire.CodeConflict, "磁盘空间不足：写入文件失败")
		}
		return fsErr(err)
	}
	s.Audit.Write("fs.upload", map[string]any{"root": a.Root, "path": rel, "bytes": n, "ms": time.Since(start).Milliseconds()})
	fi, err := root.Lstat(rel)
	if err != nil {
		return fsErr(err)
	}
	return wire.WriteJSON(st, wire.OKResponse(s.toEntry(root, rootDir, rel, fi)))
}

func rootPath(s *Env, id string) string {
	for _, r := range s.Roots {
		if r.ID == id {
			return r.Path
		}
	}
	if len(s.Roots) > 0 {
		return s.Roots[0].Path
	}
	return "/"
}

func (s *Env) fsDownload(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	a, root, rel, err := s.fsPrep(raw)
	if err != nil {
		return err
	}
	defer root.Close()
	f, err := root.Open(rel)
	if err != nil {
		return fsErr(err)
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return fsErr(err)
	}
	if !fi.Mode().IsRegular() {
		return wire.Errf(wire.CodeBadRequest, "只能下载普通文件")
	}
	if a.Offset < 0 || a.Offset > fi.Size() {
		return wire.Errf(wire.CodeBadRequest, "偏移量无效")
	}
	if _, err := f.Seek(a.Offset, io.SeekStart); err != nil {
		return fsErr(err)
	}
	n := fi.Size() - a.Offset
	if a.Length > 0 && a.Length < n {
		n = a.Length // a byte range (video seeking)
	}
	meta := map[string]any{"size": fi.Size(), "name": fi.Name(), "etag": etag(fi), "mtime": fi.ModTime().UnixMilli(), "offset": a.Offset, "length": n}
	if err := wire.WriteJSON(st, wire.OKResponse(meta)); err != nil {
		return nil
	}
	// Send exactly the size announced above. A file still being written (a
	// log) would otherwise deliver more than the client was told to expect,
	// and the client rejects a body longer than its Content-Length.
	src := io.LimitReader(f, n)
	buf := make([]byte, wire.DataChunk)
	for {
		n, rerr := src.Read(buf)
		if n > 0 {
			if err := wire.WriteFrame(st, wire.TypeData, buf[:n]); err != nil {
				return nil
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return nil // the client sees a missing 'E' and reports truncation
		}
	}
	return wire.WriteFrame(st, wire.TypeEnd, nil)
}