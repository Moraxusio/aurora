//go:build linux

package files

import (
	"context"
	"encoding/json"
	"io/fs"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"aurora3/internal/wire"
)

type duChild struct {
	Bytes int64 `json:"bytes"`
	Disk  int64 `json:"disk"`
	Files int64 `json:"files"`
	Done  bool  `json:"done"` // fully counted (false: the walk stopped inside it)
}

type duResult struct {
	Path     string              `json:"path"`
	Bytes    int64               `json:"bytes"` // sum of file sizes
	Disk     int64               `json:"disk"`  // allocated blocks, like du
	Files    int64               `json:"files"`
	Dirs     int64               `json:"dirs"`
	Partial  bool                `json:"partial"` // stopped at the deadline
	Skipped  []string            `json:"skipped,omitempty"`
	Errors   int64               `json:"errors"`
	Ms       int64               `json:"ms"`
	Children map[string]*duChild `json:"children,omitempty"`
}

// mountTable returns every mount point and its filesystem type.
func mountTable() map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(readFile("/proc/self/mounts"), "\n") {
		f := strings.Fields(line)
		if len(f) >= 3 {
			out[strings.ReplaceAll(f[1], "\\040", " ")] = f[2]
		}
	}
	return out
}

// fsTypeAt finds the filesystem holding abs by longest mount prefix, without
// touching the disk (a stat on a dead NFS mount never returns).
func fsTypeAt(mounts map[string]string, abs string) string {
	best, typ := "", ""
	for m, t := range mounts {
		if (abs == m || m == "/" || strings.HasPrefix(abs, m+"/")) && len(m) >= len(best) {
			best, typ = m, t
		}
	}
	return typ
}

// fsDu totals a directory like "du -x": it stays inside the root (os.Root),
// never enters another mount point, counts hard links once and returns what it
// has when the deadline passes.
func (s *Env) fsDu(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Root      string `json:"root"`
		Path      string `json:"path"`
		Children  bool   `json:"children"`
		TimeoutMs int    `json:"timeout_ms"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	rel, err := cleanRel(a.Path)
	if err != nil {
		return nil, err
	}
	root, err := s.openRoot(a.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	rootDir := rootPath(s, a.Root)
	mounts := mountTable()
	abs := filepath.Join(rootDir, rel)
	if t := fsTypeAt(mounts, abs); t != "" && !localFS[t] {
		return nil, wire.Errf(wire.CodeUnsupported, "网络或虚拟文件系统（%s）不统计大小", t)
	}
	fi, err := root.Stat(rel)
	if err != nil {
		return nil, fsErr(err)
	}
	if !fi.IsDir() {
		return nil, wire.Errf(wire.CodeBadRequest, "不是目录")
	}
	timeout := time.Duration(a.TimeoutMs) * time.Millisecond
	if timeout <= 0 || timeout > 45*time.Second {
		timeout = 20 * time.Second
	}
	deadline := time.Now().Add(timeout)
	start := time.Now()
	res := &duResult{Path: "/" + strings.TrimPrefix(rel, ".")}
	if a.Children {
		res.Children = map[string]*duChild{}
	}
	prefix := ""
	if rel != "." {
		prefix = rel + "/"
	}
	seen := map[[2]uint64]bool{}
	var curChild *duChild // WalkDir visits children in order: all before this one are complete
	n := 0
	_ = fs.WalkDir(root.FS(), rel, func(p string, d fs.DirEntry, err error) error {
		if n++; n%512 == 0 && (ctx.Err() != nil || time.Now().After(deadline)) {
			res.Partial = true
			return fs.SkipAll
		}
		if err != nil {
			res.Errors++
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() && p != rel {
			if _, isMount := mounts[filepath.Join(rootDir, p)]; isMount {
				if len(res.Skipped) < 50 {
					res.Skipped = append(res.Skipped, "/"+p)
				}
				return fs.SkipDir
			}
			res.Dirs++
		}
		info, err := d.Info()
		if err != nil {
			res.Errors++
			return nil
		}
		var size, disk int64
		if st, ok := info.Sys().(*syscall.Stat_t); ok {
			if !d.IsDir() && st.Nlink > 1 {
				key := [2]uint64{uint64(st.Dev), st.Ino}
				if seen[key] {
					return nil
				}
				seen[key] = true
			}
			disk = st.Blocks * 512
		}
		if !d.IsDir() {
			size = info.Size()
			res.Files++
		}
		res.Bytes += size
		res.Disk += disk
		if res.Children != nil && p != rel {
			name, _, _ := strings.Cut(strings.TrimPrefix(p, prefix), "/")
			c := res.Children[name]
			if c == nil {
				c = &duChild{}
				res.Children[name] = c
				if curChild != nil {
					curChild.Done = true
				}
				curChild = c
			}
			c.Bytes += size
			c.Disk += disk
			if !d.IsDir() {
				c.Files++
			}
		}
		return nil
	})
	if !res.Partial && curChild != nil {
		curChild.Done = true
	}
	res.Ms = time.Since(start).Milliseconds()
	return res, nil
}