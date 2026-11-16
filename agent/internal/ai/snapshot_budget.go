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
	"strconv"
	"strings"
	"sync"
	"time"
)

const snapshotFileMax = 8 << 20
const snapshotTreeMax = 128 << 20
const snapshotStoreMax = 512 << 20
const snapshotFilesMax = 20000

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
func (m *SnapshotManager) captureBounded(ctx context.Context, gitDir, work string) (string, error) {
	size, err := m.storeBytes(ctx, gitDir, work)
	if err != nil {
		return "", err
	}
	if size >= snapshotStoreMax {
		return "", errors.New("快照空间超过 512 MiB，请清理未引用快照")
	}
	names, err := m.runGit(ctx, gitDir, work, nil, "ls-files", "--others", "--exclude-standard", "-z", "--", ".",
		":(exclude).git", ":(exclude)node_modules", ":(exclude).dart_tool", ":(exclude)build", ":(exclude)target")
	if err != nil {
		return "", err
	}
	files := bytes.Split(bytes.TrimSuffix(names, []byte{0}), []byte{0})
	if len(files) > snapshotFilesMax {
		return "", errors.New("快照超过 20000 个文件")
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
		for _, raw := range files {
			if len(raw) == 0 {
				continue
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			name := string(raw)
			if info, err := root.Lstat(filepath.FromSlash(name)); err != nil || !info.Mode().IsRegular() {
				return fmt.Errorf("快照仅支持普通文件: %s", name)
			}
			f, err := root.Open(filepath.FromSlash(name))
			if err != nil {
				return err
			}
			info, err := f.Stat()
			if err != nil || !info.Mode().IsRegular() || info.Size() > snapshotFileMax {
				f.Close()
				return fmt.Errorf("snapshot target is not a regular file within 8 MiB: %s", name)
			}
			data, err := io.ReadAll(io.LimitReader(f, snapshotFileMax+1))
			f.Close()
			if err != nil {
				return err
			}
			total += len(data)
			if len(data) > snapshotFileMax || total > snapshotTreeMax || size+int64(total) > snapshotStoreMax {
				return errors.New("快照内容超过文件、工作树或存储预算")
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
