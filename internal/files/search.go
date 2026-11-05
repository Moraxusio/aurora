//go:build linux

package files

// fs.search: text search across a folder (VS Code's search view);
// fs.find: file names for quick open (Ctrl+P).
//
// Inside a git repository the files are the ones git knows about (tracked and
// untracked, not ignored), so .gitignore applies; elsewhere the folder is
// walked, skipping dependency and cache folders and every mount below it
// that is not a local disk (a dead NFS server would hang the walk).

import (
	"bytes"
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"aurora3/internal/wire"
)

const (
	searchFileMax  = 4 << 20
	listMax        = 300000
	searchDeadline = 25 * time.Second
)

// listFiles lists the files below abs, relative to it.
func (s *Env) listFiles(ctx context.Context, abs string) (files []string, via string, truncated bool, walkErrors int) {
	if s.Repos != nil {
		if r, err := s.Repos.Runner(abs); err == nil {
			lctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			names, capped, lerr := r.LsFiles(lctx, listMax)
			cancel()
			files = append(files, names...)
			truncated = capped
			if lerr == nil || truncated {
				return files, "git", truncated, 0
			}
		}
	}
	skip := foreignMounts(abs)
	stop := errorsStop
	_ = filepath.WalkDir(abs, func(p string, d fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			truncated = true
			return stop
		}
		if err != nil {
			walkErrors++
			return nil
		}
		if d.IsDir() {
			if p != abs && (skipDirs[d.Name()] || skip[p]) {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		if len(files) >= listMax {
			truncated = true
			return stop
		}
		rel, _ := filepath.Rel(abs, p)
		files = append(files, filepath.ToSlash(rel))
		return nil
	})
	return files, "walk", truncated, walkErrors
}

var errorsStop = fs.ErrClosed

// foreignMounts: mount points below abs that a walk must not enter.
func foreignMounts(abs string) map[string]bool {
	out := map[string]bool{}
	for _, line := range strings.Split(readFile("/proc/mounts"), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		mnt := strings.ReplaceAll(f[1], "\\040", " ")
		if mnt == abs || !within(abs, mnt) {
			continue
		}
		if !localFS[f[2]] || mnt == "/proc" || mnt == "/sys" || mnt == "/dev" || mnt == "/run" {
			out[mnt] = true
		}
	}
	for _, p := range []string{"/proc", "/sys", "/dev", "/run"} {
		if abs == "/" {
			out[p] = true
		}
	}
	return out
}

// ---- quick open ----

type fileList struct {
	files []string
	at    time.Time
}

var (
	listMu    sync.Mutex
	listCache = map[string]fileList{}
)

// cachedFiles: the file list of abs, listed again when older than maxAge.
func (s *Env) cachedFiles(ctx context.Context, abs string, maxAge time.Duration) []string {
	listMu.Lock()
	if c, ok := listCache[abs]; ok && time.Since(c.at) < maxAge {
		listMu.Unlock()
		return c.files
	}
	listMu.Unlock()
	files, _, _, _ := s.listFiles(ctx, abs)
	listMu.Lock()
	defer listMu.Unlock()
	if len(listCache) >= 6 {
		for k := range listCache {
			delete(listCache, k)
			break
		}
	}
	listCache[abs] = fileList{files: files, at: time.Now()}
	return files
}

func (s *Env) fsFind(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Root  string `json:"root"`
		Path  string `json:"path"`
		Query string `json:"query"`
		Max   int    `json:"max"`
		// Fresh: the first query of a quick open; files made since are found.
		Fresh bool `json:"fresh"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Max <= 0 || a.Max > 500 {
		a.Max = 100
	}
	_, abs, err := s.dirOf(a.Root, a.Path)
	if err != nil {
		return nil, err
	}
	age := 30 * time.Second
	if a.Fresh {
		age = 2 * time.Second
	}
	files := s.cachedFiles(ctx, abs, age)
	ranked := rankFiles(files, strings.TrimSpace(a.Query), a.Max)
	out := make([]string, len(ranked))
	for i, f := range ranked {
		out[i] = relJoin(a.Path, f.Path)
	}
	return map[string]any{"files": out, "total": len(files)}, nil
}

// ---- text search ----

type fileMatches struct {
	Path    string      `json:"path"`
	Matches []lineMatch `json:"matches"`
}

func (s *Env) fsSearch(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Root    string `json:"root"`
		Path    string `json:"path"`
		Query   string `json:"query"`
		Regex   bool   `json:"regex"`
		Case    bool   `json:"case"`
		Word    bool   `json:"word"`
		Include string `json:"include"`
		Exclude string `json:"exclude"`
		Max     int    `json:"max"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Query == "" || len(a.Query) > 1000 {
		return nil, wire.Errf(wire.CodeBadRequest, "搜索内容为空或过长")
	}
	if a.Max <= 0 || a.Max > 20000 {
		a.Max = 2000
	}
	re, err := buildMatcher(a.Query, a.Regex, a.Case, a.Word)
	if err != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "表达式无效：%v", err)
	}
	_, abs, err := s.dirOf(a.Root, a.Path)
	if err != nil {
		return nil, err
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(ctx, searchDeadline)
	defer cancel()
	files, via, listTrunc, walkErrors := s.listFiles(ctx, abs)
	inc, exc := parseGlobs(a.Include), parseGlobs(a.Exclude)
	work := make(chan string, 256)
	var (
		mu       sync.Mutex
		results  []fileMatches
		total    atomic.Int64
		scanned  atomic.Int64
		skipped  atomic.Int64
		limitHit atomic.Bool
		wg       sync.WaitGroup
	)
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for rel := range work {
				if ctx.Err() != nil || limitHit.Load() {
					continue
				}
				p := filepath.Join(abs, rel)
				fi, err := os.Lstat(p)
				if err != nil || !fi.Mode().IsRegular() {
					continue
				}
				if fi.Size() > searchFileMax {
					skipped.Add(1)
					continue
				}
				b, err := os.ReadFile(p)
				if err != nil {
					continue
				}
				scanned.Add(1)
				head := b
				if len(head) > 8000 {
					head = head[:8000]
				}
				if bytes.IndexByte(head, 0) >= 0 {
					continue
				}
				left := a.Max - int(total.Load())
				if left <= 0 {
					limitHit.Store(true)
					continue
				}
				ms := matchLines(b, re, min(left, 500))
				if len(ms) == 0 {
					continue
				}
				if total.Add(int64(len(ms))) >= int64(a.Max) {
					limitHit.Store(true)
				}
				mu.Lock()
				results = append(results, fileMatches{Path: relJoin(a.Path, rel), Matches: ms})
				mu.Unlock()
			}
		}()
	}
	for _, f := range files {
		if limitHit.Load() || ctx.Err() != nil {
			break
		}
		if len(inc) > 0 && !inc.match(f) || exc.match(f) {
			continue
		}
		work <- f
	}
	close(work)
	wg.Wait()
	sort.Slice(results, func(i, j int) bool { return results[i].Path < results[j].Path })
	if results == nil {
		results = []fileMatches{}
	}
	return map[string]any{
		"files": results, "total": total.Load(), "scanned": scanned.Load(), "skipped_large": skipped.Load(),
		"truncated": limitHit.Load() || listTrunc || ctx.Err() != nil, "timed_out": ctx.Err() != nil,
		"incomplete": walkErrors > 0, "errors": walkErrors,
		"via": via, "ms": time.Since(start).Milliseconds(),
	}, nil
}

// ---- log files ----

type logFile struct {
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"`
}

// fs.logs: the log files below a folder, most recently written first.
func (s *Env) fsLogs(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Root string `json:"root"`
		Path string `json:"path"`
		Max  int    `json:"max"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Max <= 0 || a.Max > 200 {
		a.Max = 50
	}
	_, abs, err := s.dirOf(a.Root, a.Path)
	if err != nil {
		return nil, err
	}
	var out []logFile
	for _, rel := range s.cachedFiles(ctx, abs, 10*time.Second) {
		if !logName(rel) {
			continue
		}
		fi, err := os.Stat(filepath.Join(abs, rel))
		if err != nil || !fi.Mode().IsRegular() {
			continue
		}
		out = append(out, logFile{Path: relJoin(a.Path, rel), Size: fi.Size(), Mtime: fi.ModTime().UnixMilli()})
		if len(out) >= 5000 {
			break
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Mtime > out[j].Mtime })
	if len(out) > a.Max {
		out = out[:a.Max]
	}
	if out == nil {
		out = []logFile{}
	}
	return map[string]any{"files": out}, nil
}
// dirOf resolves a root-relative path to its absolute, symlink-checked form.
// Copied from v2 gitrun.go; the git service does not need it, search does.
func (s *Env) dirOf(rootID, p string) (rootAbs, abs string, err error) {
	rel, err := cleanRel(p)
	if err != nil {
		return "", "", err
	}
	r, err := s.openRoot(rootID)
	if err != nil {
		return "", "", err
	}
	r.Close()
	rootAbs = rootPath(s, rootID)
	if real, e := filepath.EvalSymlinks(rootAbs); e == nil {
		rootAbs = real
	}
	abs, err = filepath.EvalSymlinks(filepath.Join(rootAbs, rel))
	if err != nil {
		return "", "", fsErr(err)
	}
	if !within(rootAbs, abs) {
		return "", "", wire.Errf(wire.CodeForbidden, "不允许访问根目录以外的路径")
	}
	return rootAbs, abs, nil
}

