//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"aurora3/internal/filetxn"
	"aurora3/internal/paths"
	"aurora3/internal/statecrypt"
)

const protectedTreeMax = 64 << 20

var snapshotObject = regexp.MustCompile(`^[a-f0-9]{64}$`)

type protectedFile struct {
	Blob string `json:"blob"`
	Exec bool   `json:"exec,omitempty"`
}

type protectedSnapshots struct {
	dir   string
	codec *statecrypt.Codec
}

func (m *SnapshotManager) protected(work string) *protectedSnapshots {
	if codec := statecrypt.Current(); codec != nil {
		return newProtectedSnapshots(m.BaseDir, work, codec)
	}
	return nil
}

func newProtectedSnapshots(base, work string, codec *statecrypt.Codec) *protectedSnapshots {
	id := codec.ObjectID("snapshot-workspace", []byte(filepath.Clean(work)))
	return &protectedSnapshots{dir: filepath.Join(base, hex.EncodeToString(id[:])+".protected"), codec: codec}
}

func (m *SnapshotManager) protectedSelection(ctx context.Context, work string, policy SnapshotOptions) ([]snapshotFile, int, error) {
	git, err := exec.LookPath("git")
	if err != nil {
		return nil, 0, err
	}
	// This repository is used exclusively for ls-files in non-Git directories.
	// It has no index or source objects, and is never passed to fast-import.
	dir, err := m.ensureGitDir(ctx, git, m.protected(work).dir+".selection")
	if err != nil {
		return nil, 0, err
	}
	files, skipped, err := m.snapshotFiles(ctx, dir, work, policy)
	if err != nil {
		return nil, 0, err
	}
	stateDir := filepath.Dir(filepath.Dir(m.BaseDir))
	result := files[:0]
	for _, file := range files {
		if paths.Within(stateDir, filepath.Join(work, filepath.FromSlash(file.name))) {
			skipped++
			continue
		}
		if !utf8.ValidString(file.name) {
			return nil, 0, errors.New("快照路径不是有效的 UTF-8，未捕获新快照")
		}
		result = append(result, file)
	}
	return result, skipped, nil
}

func (p *protectedSnapshots) context(kind string) string {
	return kind + ":" + filepath.Base(p.dir)
}

func (p *protectedSnapshots) id(kind string, data []byte) string {
	id := p.codec.ObjectID(p.context(kind), data)
	return hex.EncodeToString(id[:])
}

func (p *protectedSnapshots) read(kind, id string, max int64) ([]byte, error) {
	if !snapshotObject.MatchString(id) {
		return nil, errors.New("未迁移或无效的快照对象引用")
	}
	path := filepath.Join(p.dir, id+"."+kind)
	stored, err := readSessionFile(path, max+int64(statecrypt.Overhead))
	if err != nil {
		return nil, err
	}
	data, err := p.codec.Open("ai:"+p.context(kind)+":"+filepath.Base(path), stored)
	if err == nil && p.id(kind, data) != id {
		return nil, errors.New("快照对象与其引用不匹配")
	}
	return data, err
}

func (p *protectedSnapshots) tree(id string) (map[string]protectedFile, error) {
	b, err := p.read("tree", id, protectedTreeMax)
	if err != nil {
		return nil, err
	}
	var tree map[string]protectedFile
	if json.Unmarshal(b, &tree) != nil || tree == nil || len(tree) > 2000000 {
		return nil, errors.New("无效的加密快照清单")
	}
	for name, value := range tree {
		rel := filepath.FromSlash(name)
		if !filepath.IsLocal(rel) || rel == "." || strings.ContainsRune(rel, 0) ||
			filepath.ToSlash(filepath.Clean(rel)) != name || !snapshotObject.MatchString(value.Blob) {
			return nil, errors.New("无效的快照文件路径或引用")
		}
	}
	return tree, nil
}

func (p *protectedSnapshots) inventory() (map[string]int64, int64, error) {
	out := map[string]int64{}
	entries, err := os.ReadDir(p.dir)
	if os.IsNotExist(err) {
		return out, 0, nil
	}
	if err != nil {
		return nil, 0, err
	}
	var total int64
	for _, entry := range entries {
		fi, err := entry.Info()
		if err != nil || !fi.Mode().IsRegular() {
			return nil, 0, errors.New("快照目录包含不可读或非普通文件")
		}
		out[entry.Name()] = fi.Size()
		total += fi.Size()
	}
	return out, total, nil
}

func (p *protectedSnapshots) writer(limit int64) (func(string, []byte, int64) (string, error), error) {
	known, used, err := p.inventory()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(p.dir, 0o700); err != nil {
		return nil, err
	}
	// Durably publish content before the manifest. Any unreferenced records
	// after interruption remain encrypted and can be pruned independently.
	return func(kind string, b []byte, max int64) (string, error) {
		if int64(len(b)) > max {
			return "", errors.New("快照对象超出预算")
		}
		id := p.id(kind, b)
		name := id + "." + kind
		if _, exists := known[name]; exists {
			existing, err := p.read(kind, id, max)
			clear(existing)
			if err != nil {
				return "", err
			}
			return id, nil
		}
		size := int64(len(b) + statecrypt.Overhead)
		if used+size > limit {
			return "", errors.New("加密快照存储超过上限，未发布新快照")
		}
		if err := writeClonedRecord(p.codec, p.context(kind), filepath.Join(p.dir, name), b); err != nil {
			return "", err
		}
		used += size
		known[name] = size
		return id, nil
	}, nil
}

func (p *protectedSnapshots) capture(ctx context.Context, work string, files []snapshotFile, policy SnapshotOptions) (string, error) {
	put, err := p.writer(int64(policy.MaxStoreBytes))
	if err != nil {
		return "", err
	}
	root, err := os.OpenRoot(work)
	if err != nil {
		return "", err
	}
	defer root.Close()
	filesByName := make(map[string]protectedFile, len(files))
	var total int64
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		data, mode, err := readCaptureFile(root, filepath.FromSlash(file.name), int64(policy.MaxFileBytes))
		if err != nil {
			return "", err
		}
		total += int64(len(data))
		if total > int64(policy.MaxTreeBytes) {
			return "", errors.New("加密快照内容超过单树上限")
		}
		id, err := put("blob", data, filetxn.MaxFileBytes)
		clear(data)
		if err != nil {
			return "", err
		}
		filesByName[file.name] = protectedFile{Blob: id, Exec: mode&0o111 != 0}
	}
	manifest, err := json.Marshal(filesByName)
	if err != nil {
		return "", err
	}
	defer clear(manifest)
	if len(manifest) > protectedTreeMax {
		return "", errors.New("加密快照清单超过上限")
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return put("tree", manifest, protectedTreeMax)
}

func readCaptureFile(root *os.Root, path string, max int64) ([]byte, os.FileMode, error) {
	fi, err := root.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > max {
		return nil, 0, fmt.Errorf("无法捕获已变化的文件：%s", path)
	}
	f, err := root.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(fi, opened) {
		return nil, 0, fmt.Errorf("快照文件在打开时已变化：%s", path)
	}
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, 0, err
	}
	after, err := f.Stat()
	if err != nil || int64(len(data)) > max || int64(len(data)) != fi.Size() ||
		after.Size() != fi.Size() || !after.ModTime().Equal(fi.ModTime()) {
		return nil, 0, fmt.Errorf("快照文件在读取期间已变化：%s", path)
	}
	return data, fi.Mode(), nil
}

func (p *protectedSnapshots) pair(ctx context.Context, from, to string) ([]FileDiff, error) {
	old, err := p.tree(from)
	if err != nil {
		return nil, err
	}
	next, err := p.tree(to)
	if err != nil {
		return nil, err
	}
	var paths []string
	for name := range old {
		if old[name] != next[name] {
			paths = append(paths, name)
		}
	}
	for name := range next {
		if _, exists := old[name]; !exists {
			paths = append(paths, name)
		}
	}
	if len(paths) > 128 {
		return nil, errors.New("快照差异超过 128 个文件事务预算")
	}
	sort.Strings(paths)
	diffs := make([]FileDiff, 0, len(paths))
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		before, err := p.file(old[path])
		if err != nil {
			return nil, err
		}
		after, err := p.file(next[path])
		if err != nil {
			return nil, err
		}
		d := FileDiff{File: path, Status: "modified"}
		if len(before.Data)+len(after.Data) <= 512<<10 &&
			utf8.Valid(before.Data) && utf8.Valid(after.Data) &&
			bytes.IndexByte(before.Data, 0) == -1 && bytes.IndexByte(after.Data, 0) == -1 {
			d = ComputeFileDiff(path, string(before.Data), string(after.Data))
			d.Patch = truncateUTF8Prefix(d.Patch, 16<<10)
		} else {
			d.Patch = "...[binary or large file: preview omitted]"
		}
		switch {
		case !before.Exists:
			d.Status = "added"
		case !after.Exists:
			d.Status = "deleted"
		default:
			d.Status = "modified"
		}
		diffs = append(diffs, d)
	}
	return diffs, nil
}

func (p *protectedSnapshots) file(ref protectedFile) (filetxn.State, error) {
	state := filetxn.State{UID: -1, GID: -1}
	if ref.Blob == "" {
		return state, nil
	}
	b, err := p.read("blob", ref.Blob, filetxn.MaxFileBytes)
	if err != nil {
		return state, err
	}
	state.Exists, state.Data, state.Mode = true, b, 0o644
	if ref.Exec {
		state.Mode = 0o755
	}
	return state, nil
}

func (p *protectedSnapshots) plan(ctx context.Context, work string, first, last map[string]string) ([]filetxn.Change, error) {
	trees := map[string]map[string]protectedFile{}
	load := func(id, path string) (filetxn.State, error) {
		tree, cached := trees[id]
		if !cached {
			var err error
			tree, err = p.tree(id)
			if err != nil {
				return filetxn.State{}, err
			}
			// Cache only a couple of manifests; many turns can reference
			// distinct trees, each with a large set of files.
			if len(trees) >= 2 {
				clear(trees)
			}
			trees[id] = tree
		}
		return p.file(tree[path])
	}
	var out []filetxn.Change
	total := 0
	for path, start := range first {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		rel := filepath.FromSlash(path)
		if len(out) >= filetxn.MaxChanges || !filepath.IsLocal(rel) || rel == "." || strings.ContainsRune(rel, 0) ||
			filepath.ToSlash(filepath.Clean(rel)) != path {
			return nil, errors.New("无效的快照回退范围")
		}
		before, err := load(last[path], path)
		if err != nil {
			return nil, err
		}
		after, err := load(start, path)
		if err != nil {
			return nil, err
		}
		total += len(before.Data) + len(after.Data)
		if total > filetxn.MaxTransactionBytes {
			return nil, errors.New("加密快照回退超过文件事务预算")
		}
		before.Mode = 0 // Like legacy Git snapshots, permissions are partial.
		out = append(out, filetxn.Change{Root: work, Path: rel, Before: before, After: after})
	}
	return out, nil
}

func (p *protectedSnapshots) prune(ctx context.Context, keep map[string]bool) (map[string]int64, error) {
	known, before, err := p.inventory()
	if err != nil {
		return nil, err
	}
	blobs := map[string]bool{}
	// Validate retained manifests before making any deletion.
	for tree := range keep {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		files, err := p.tree(tree)
		if err != nil {
			return nil, err
		}
		for _, file := range files {
			if _, ok := known[file.Blob+".blob"]; !ok {
				return nil, errors.New("引用的快照内容缺失，已取消清理")
			}
			blobs[file.Blob] = true
		}
	}
	// Remove dropped manifests before deleting their unshared content.
	after := before
	for _, kind := range []string{"tree", "blob"} {
		for name, size := range known {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			id, ok := strings.CutSuffix(name, "."+kind)
			if !ok || !snapshotObject.MatchString(id) || (kind == "tree" && keep[id]) || (kind == "blob" && blobs[id]) {
				continue
			}
			if err := os.Remove(filepath.Join(p.dir, name)); err != nil {
				return nil, err
			}
			after -= size
		}
	}
	return map[string]int64{"beforeBytes": before, "afterBytes": after}, nil
}
