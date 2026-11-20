//go:build linux || windows

package ai

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const snapshotFileMax = 8 << 20
const snapshotTreeMax = 128 << 20
const snapshotStoreMax = 512 << 20
const snapshotFilesMax = 200000

// Defaults follow OpenCode's eligibility model: track source files, respect
// Git's own excludes and skip large untracked artifacts instead of failing the
// whole step. Aurora additionally supports explicitly chosen non-Git folders.
type SnapshotOptions struct {
	MaxFiles       int      `json:"maxFiles,omitempty"`
	MaxFileBytes   int      `json:"maxFileBytes,omitempty"`
	MaxTreeBytes   int      `json:"maxTreeBytes,omitempty"`
	MaxStoreBytes  int      `json:"maxStoreBytes,omitempty"`
	TimeoutSeconds int      `json:"timeoutSeconds,omitempty"`
	Ignore         []string `json:"ignore,omitempty"`
}

func defaultSnapshotOptions() SnapshotOptions {
	return SnapshotOptions{MaxFiles: snapshotFilesMax, MaxFileBytes: snapshotFileMax,
		MaxTreeBytes: snapshotTreeMax, MaxStoreBytes: snapshotStoreMax, TimeoutSeconds: 60, Ignore: []string{}}
}
func (o *SnapshotOptions) resolved() SnapshotOptions {
	out := defaultSnapshotOptions()
	if o == nil {
		return out
	}
	if o.MaxFiles > 0 {
		out.MaxFiles = o.MaxFiles
	}
	if o.MaxFileBytes > 0 {
		out.MaxFileBytes = o.MaxFileBytes
	}
	if o.MaxTreeBytes > 0 {
		out.MaxTreeBytes = o.MaxTreeBytes
	}
	if o.MaxStoreBytes > 0 {
		out.MaxStoreBytes = o.MaxStoreBytes
	}
	if o.TimeoutSeconds > 0 {
		out.TimeoutSeconds = o.TimeoutSeconds
	}
	out.Ignore = o.Ignore
	return out
}
func (o *SnapshotOptions) validate() error {
	if o == nil {
		return nil
	}
	if o.MaxFiles < 0 || o.MaxFiles > 2000000 || o.MaxFileBytes < 0 || o.MaxFileBytes > 64<<20 ||
		o.MaxTreeBytes < 0 || o.MaxTreeBytes > 1<<30 || o.MaxStoreBytes < 0 || o.MaxStoreBytes > 16<<30 ||
		o.TimeoutSeconds < 0 || o.TimeoutSeconds > 600 || len(o.Ignore) > 64 {
		return errors.New("快照设置超出范围：最多 200 万文件、单文件 64 MiB、单树 1 GiB、存储 16 GiB、超时 600 秒")
	}
	for _, pattern := range o.Ignore {
		if pattern == "" || strings.ContainsAny(pattern, "\x00\r\n") || len(pattern) > 1024 {
			return errors.New("快照忽略模式须为非空的项目相对 glob")
		}
	}
	return nil
}

type snapshotFile struct {
	name string
	size int64
}

func (m *SnapshotManager) snapshotFiles(ctx context.Context, gitDir, work string, policy SnapshotOptions) ([]snapshotFile, int, error) {
	// Resolve the real repository from the active directory, never by walking
	// its parent as snapshot scope. Read-only ls-files preserves the real index
	// and inherits ancestor .gitignore, info/exclude and global excludes.
	real := quietCommandContext(ctx, "git", "-C", work, "rev-parse", "--absolute-git-dir")
	repo, realErr := real.Output()
	listDir := gitDir
	if realErr == nil {
		listDir = strings.TrimSpace(string(repo))
	}
	list := func(tracked bool) ([]byte, error) {
		args := []string{"ls-files", "-z"}
		if tracked {
			args = append(args, "--cached")
		} else {
			args = append(args, "--others", "--exclude-standard")
		}
		args = append(args, "--", ".")
		for _, pattern := range policy.Ignore {
			args = append(args, ":(glob,exclude)"+pattern)
		}
		args = append(args, ":(glob,exclude)**/.git", ":(glob,exclude)**/.git/**")
		if !tracked {
			for _, dir := range []string{"node_modules", ".dart_tool", "build", "target", "dist", ".venv", ".next", ".cache"} {
				args = append(args, ":(glob,exclude)**/"+dir+"/**")
			}
		}
		// For a real worktree, Git must derive its actual top-level itself;
		// --work-tree=work would break nested active-directory paths.
		if realErr == nil {
			cmd := quietCommandContext(ctx, "git", "-C", work)
			cmd.Args = append(cmd.Args, args...)
			out, stderr := newSnapshotBuffer(64<<20), newSnapshotBuffer(16<<10)
			cmd.Stdout, cmd.Stderr = out, stderr
			if err := cmd.Run(); err != nil {
				return nil, fmt.Errorf("读取 Git 快照范围失败：%w (%s)", err, stderr.String())
			}
			if out.truncated {
				return nil, errors.New("快照路径清单超过 64 MiB，请缩小会话目录或设置忽略规则")
			}
			return out.Bytes(), nil
		}
		return m.runGit(ctx, listDir, work, nil, args...)
	}
	entries := map[string]bool{}
	if realErr == nil {
		names, err := list(true)
		if err != nil {
			return nil, 0, err
		}
		for _, raw := range bytes.Split(names, []byte{0}) {
			if len(raw) > 0 {
				entries[string(raw)] = true
			}
		}
	}
	names, err := list(false)
	if err != nil {
		return nil, 0, err
	}
	for _, raw := range bytes.Split(names, []byte{0}) {
		if len(raw) > 0 {
			name := string(raw)
			if _, ok := entries[name]; !ok {
				entries[name] = false
			}
		}
	}
	root, err := os.OpenRoot(work)
	if err != nil {
		return nil, 0, err
	}
	defer root.Close()
	files := make([]snapshotFile, 0, len(entries))
	skipped := 0
	for name, tracked := range entries {
		if !filepath.IsLocal(filepath.FromSlash(name)) {
			return nil, skipped, errors.New("快照路径超出会话目录")
		}
		info, err := root.Lstat(filepath.FromSlash(name))
		if os.IsNotExist(err) {
			continue
		} // tracked deletion
		if err != nil {
			return nil, skipped, err
		}
		if !info.Mode().IsRegular() || (!tracked && info.Size() > min(int64(2<<20), int64(policy.MaxFileBytes))) {
			skipped++
			continue
		}
		if info.Size() > int64(policy.MaxFileBytes) {
			return nil, skipped, fmt.Errorf("已跟踪文件 %s 为 %d 字节，超过快照单文件上限 %d；可在项目「快照」中调整或忽略该路径", name, info.Size(), policy.MaxFileBytes)
		}
		files = append(files, snapshotFile{name, info.Size()})
	}
	if len(files) > policy.MaxFiles {
		return nil, skipped, fmt.Errorf("快照有效范围为 %d 个文件，超过设置的 %d；请缩小会话目录、完善 .gitignore，或在项目「快照」中调整上限/忽略规则", len(files), policy.MaxFiles)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].name < files[j].name })
	return files, skipped, nil
}

type snapshotLease struct {
	mu    sync.Mutex
	users int
}

func (m *SnapshotManager) lock(work string) func() {
	key := m.shadowGitDir(work)
	m.mu.Lock()
	if m.locks == nil {
		m.locks = map[string]*snapshotLease{}
	}
	lease := m.locks[key]
	if lease == nil {
		lease = &snapshotLease{}
		m.locks[key] = lease
	}
	lease.users++
	m.mu.Unlock()
	lease.mu.Lock()
	return func() {
		lease.mu.Unlock()
		m.mu.Lock()
		lease.users--
		if lease.users == 0 {
			delete(m.locks, key)
		}
		m.mu.Unlock()
	}
}

type snapshotBuffer struct {
	bytes.Buffer
	limit     int
	truncated bool
}

func newSnapshotBuffer(limit int) *snapshotBuffer { return &snapshotBuffer{limit: limit} }
func (b *snapshotBuffer) Write(p []byte) (int, error) {
	count := len(p)
	remaining := b.limit - b.Len()
	if len(p) > remaining {
		p = p[:remaining]
		b.truncated = true
	}
	_, _ = b.Buffer.Write(p)
	return count, nil
}
func (m *SnapshotManager) storeBytes(ctx context.Context, gitDir, work string) (int64, error) {
	out, err := m.runGit(ctx, gitDir, work, nil, "count-objects", "-v")
	if err != nil {
		return 0, err
	}
	var total int64
	for _, line := range strings.Split(string(out), "\n") {
		name, value, ok := strings.Cut(line, ": ")
		if !ok {
			continue
		}
		if name == "size" || name == "size-pack" {
			n, _ := strconv.ParseInt(value, 10, 64)
			total += n * 1024
		}
	}
	return total, nil
}

// Fast-import hashes a bounded file at a time through a pipe. Git never reads
// unbounded working files itself. A fresh tree also preserves deletions without
// writing the user's index or creating a chain that prevents later GC.
func (m *SnapshotManager) captureBounded(ctx context.Context, gitDir, work string, policy SnapshotOptions) (string, error) {
	size, err := m.storeBytes(ctx, gitDir, work)
	if err != nil {
		return "", err
	}
	if size >= int64(policy.MaxStoreBytes) {
		return "", fmt.Errorf("快照存储 %d 字节已达到上限 %d；可在项目「快照」中清理未引用对象或调整上限", size, policy.MaxStoreBytes)
	}
	files, _, err := m.snapshotFiles(ctx, gitDir, work, policy)
	if err != nil {
		return "", err
	}
	root, err := os.OpenRoot(work)
	if err != nil {
		return "", err
	}
	defer root.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := quietCommandContext(ctx, "git", "--git-dir="+gitDir, "fast-import", "--quiet", "--force")
	cmd.Dir = work
	out, stderr := newSnapshotBuffer(4096), newSnapshotBuffer(16384)
	cmd.Stdout = out
	cmd.Stderr = stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		in.Close()
		return "", err
	}
	writeErr := func() error {
		w := bufio.NewWriterSize(in, 64<<10)
		_, err := fmt.Fprint(w, "reset refs/aurora/current\n\ncommit refs/aurora/current\ncommitter Aurora <aurora@localhost> 0 +0000\ndata 0\n\ndeleteall\n")
		if err != nil {
			return err
		}
		total := 0
		for _, entry := range files {
			if err := ctx.Err(); err != nil {
				return err
			}
			name := entry.name
			if info, err := root.Lstat(filepath.FromSlash(name)); err != nil || !info.Mode().IsRegular() {
				return fmt.Errorf("快照仅支持普通文件: %s", name)
			}
			f, err := root.Open(filepath.FromSlash(name))
			if err != nil {
				return err
			}
			info, err := f.Stat()
			if err != nil || !info.Mode().IsRegular() || info.Size() > int64(policy.MaxFileBytes) {
				f.Close()
				return fmt.Errorf("快照文件读取时已变化或超过 %d 字节：%s", policy.MaxFileBytes, name)
			}
			data, err := io.ReadAll(io.LimitReader(f, int64(policy.MaxFileBytes)+1))
			f.Close()
			if err != nil {
				return err
			}
			total += len(data)
			if len(data) > policy.MaxFileBytes || total > policy.MaxTreeBytes {
				return fmt.Errorf("快照内容超过单文件 %d / 单树 %d 字节上限；请在项目「快照」中调整范围或上限", policy.MaxFileBytes, policy.MaxTreeBytes)
			}
			mode := "100644"
			if info.Mode()&0111 != 0 {
				mode = "100755"
			}
			if _, err := fmt.Fprintf(w, "M %s inline %s\ndata %d\n", mode, snapshotQuote(name), len(data)); err != nil {
				return err
			}
			if _, err := w.Write(data); err != nil {
				return err
			}
			if err := w.WriteByte('\n'); err != nil {
				return err
			}
		}
		if _, err := w.WriteString("\n"); err != nil {
			return err
		}
		return w.Flush()
	}()
	in.Close()
	if writeErr != nil {
		cancel()
	}
	waitErr := cmd.Wait()
	if writeErr != nil {
		return "", writeErr
	}
	if waitErr != nil {
		return "", fmt.Errorf("git fast-import: %w (%s)", waitErr, stderr.String())
	}
	actual, err := m.storeBytes(ctx, gitDir, work)
	if err != nil {
		return "", err
	}
	if actual > int64(policy.MaxStoreBytes) {
		return "", fmt.Errorf("快照对象库实际占用 %d 字节，超过上限 %d；请清理未引用对象或调整存储上限", actual, policy.MaxStoreBytes)
	}
	tree, err := m.runGit(ctx, gitDir, work, nil, "rev-parse", "refs/aurora/current^{tree}")
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(string(tree))
	if _, err = m.runGit(ctx, gitDir, work, nil, "update-ref", "refs/aurora/trees/"+id, id); err != nil {
		return "", err
	}
	return id, nil
}

func snapshotQuote(name string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range []byte(name) {
		if c < 32 || c >= 127 {
			fmt.Fprintf(&b, `\%03o`, c)
		} else {
			if c == '"' || c == '\\' {
				b.WriteByte('\\')
			}
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// Prune removes only snapshot refs absent from all retained session records.
// Callers exclude running/maintenance sessions before collecting the keep set.
func (m *SnapshotManager) Prune(ctx context.Context, work string, keep map[string]bool) (map[string]int64, error) {
	if m == nil || m.BaseDir == "" {
		return nil, errors.New("快照存储不可用")
	}
	unlock := m.lock(work)
	defer unlock()
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if store := m.protected(work); store != nil {
		return store.prune(ctx, keep)
	}
	gitDir, err := m.ensureRepo(ctx, work)
	if err != nil {
		return nil, err
	}
	before, err := m.storeBytes(ctx, gitDir, work)
	if err != nil {
		return nil, err
	}
	refs, err := m.runGit(ctx, gitDir, work, nil, "for-each-ref", "--format=%(refname)", "refs/aurora/trees/")
	if err != nil {
		return nil, err
	}
	// Pin legacy snapshots too: older installations recorded tree IDs without refs.
	for tree := range keep {
		if len(tree) != 40 && len(tree) != 64 {
			return nil, errors.New("无效的保留快照标识")
		}
		for _, c := range tree {
			if !strings.ContainsRune("0123456789abcdef", c) {
				return nil, errors.New("无效的快照标识")
			}
		}
		if _, err = m.runGit(ctx, gitDir, work, nil, "update-ref", "refs/aurora/trees/"+tree, tree); err != nil {
			return nil, err
		}
	}
	for _, ref := range strings.Fields(string(refs)) {
		if keep[strings.TrimPrefix(ref, "refs/aurora/trees/")] {
			continue
		}
		if _, err = m.runGit(ctx, gitDir, work, nil, "update-ref", "-d", ref); err != nil {
			return nil, err
		}
	}
	if _, err = m.runGit(ctx, gitDir, work, nil, "update-ref", "-d", "refs/aurora/current"); err != nil {
		return nil, err
	}
	if _, err = m.runGit(ctx, gitDir, work, nil, "gc", "--prune=now", "--quiet"); err != nil {
		return nil, err
	}
	after, err := m.storeBytes(ctx, gitDir, work)
	return map[string]int64{"beforeBytes": before, "afterBytes": after}, err
}
