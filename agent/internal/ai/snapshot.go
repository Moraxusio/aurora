//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"aurora3/internal/filetxn"
)

// SnapshotManager implements OpenCode's zero-pollution shadow-git snapshot system.
// It maintains a bare git directory under <StateDir>/ai/snapshots/<hash> while
// pointing GIT_WORK_TREE at the workspace folder, so capturing trees and restoring
// files never touches or dirties the user's real .git/index or commit history.
type SnapshotManager struct {
	BaseDir string
	mu      sync.Mutex
	locks   map[string]*snapshotLease
}

// PlanRestore checks the current working file against the last AI-produced
// snapshot when committed. Reading Git objects here never changes the worktree.
func (m *SnapshotManager) PlanRestore(ctx context.Context, worktree string, first, last map[string]string) ([]filetxn.Change, error) {
	if m == nil || m.BaseDir == "" {
		return nil, fmt.Errorf("snapshot storage unavailable")
	}
	unlock := m.lock(worktree)
	defer unlock()
	if store := m.protected(worktree); store != nil {
		return store.plan(ctx, worktree, first, last)
	}
	gitDir, err := m.ensureRepo(ctx, worktree)
	if err != nil {
		return nil, err
	}
	read := func(tree, rel string) (filetxn.State, error) {
		s := filetxn.State{UID: -1, GID: -1}
		if tree == "" {
			return s, fmt.Errorf("missing expected snapshot for %s", rel)
		}
		out, err := m.runGit(ctx, gitDir, worktree, nil, "--literal-pathspecs", "ls-tree", "-z", tree, "--", filepath.ToSlash(rel))
		if err != nil {
			return s, err
		}
		if len(out) == 0 {
			return s, nil
		}
		meta, _, ok := strings.Cut(string(out), "\t")
		fields := strings.Fields(meta)
		if !ok || len(fields) != 3 || (fields[0] != "100644" && fields[0] != "100755") {
			return s, fmt.Errorf("snapshot target is not a regular file: %s", rel)
		}
		sizeOut, err := m.runGit(ctx, gitDir, worktree, nil, "cat-file", "-s", fields[2])
		if err != nil {
			return s, err
		}
		size, err := strconv.ParseInt(strings.TrimSpace(string(sizeOut)), 10, 64)
		if err != nil || size < 0 || size > filetxn.MaxFileBytes {
			return s, fmt.Errorf("snapshot file exceeds transaction budget: %s", rel)
		}
		s.Data, err = m.runGit(ctx, gitDir, worktree, nil, "cat-file", "blob", fields[2])
		s.Exists, s.Mode = true, 0o644
		if fields[0] == "100755" {
			s.Mode = 0o755
		}
		return s, err
	}
	var changes []filetxn.Change
	for path, from := range first {
		rel := filepath.Clean(filepath.FromSlash(path))
		if rel == "." || !filepath.IsLocal(rel) {
			return nil, fmt.Errorf("restore path escapes worktree: %s", path)
		}
		before, err := read(last[path], rel)
		if err != nil {
			return nil, err
		}
		after, err := read(from, rel)
		if err != nil {
			return nil, err
		}
		before.Mode = 0 // Git tracks executable only, not the complete disk mode.
		changes = append(changes, filetxn.Change{Root: worktree, Path: rel, Before: before, After: after})
	}
	return changes, nil
}

func NewSnapshotManager(stateDir string) *SnapshotManager {
	if stateDir == "" {
		return &SnapshotManager{}
	}
	return &SnapshotManager{
		BaseDir: filepath.Join(stateDir, "ai", "snapshots"),
	}
}

func (m *SnapshotManager) shadowGitDir(worktree string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(worktree)))
	return filepath.Join(m.BaseDir, hex.EncodeToString(sum[:12]))
}

func (m *SnapshotManager) ensureRepo(ctx context.Context, worktree string) (string, error) {
	if m == nil || m.BaseDir == "" {
		return "", fmt.Errorf("snapshots disabled")
	}
	gitPath, err := exec.LookPath("git")
	if err != nil {
		return "", err
	}
	return m.ensureGitDir(ctx, gitPath, m.shadowGitDir(worktree))
}

func (m *SnapshotManager) ensureGitDir(ctx context.Context, gitPath, gitDir string) (string, error) {
	if _, err := os.Stat(filepath.Join(gitDir, "HEAD")); err == nil {
		return gitDir, nil
	}
	if err := os.MkdirAll(gitDir, 0o700); err != nil {
		return "", err
	}
	cmd := quietCommandContext(ctx, gitPath, "--git-dir="+gitDir, "init", "--bare", "--quiet")
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("git init shadow: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	// Configure fast snapshot behavior matching OpenCode's opencode.gitconfig
	_, _ = quietCommandContext(ctx, gitPath, "--git-dir="+gitDir, "config", "core.autocrlf", "false").CombinedOutput()
	_, _ = quietCommandContext(ctx, gitPath, "--git-dir="+gitDir, "config", "core.quotepath", "false").CombinedOutput()
	return gitDir, nil
}

func (m *SnapshotManager) runGit(ctx context.Context, gitDir, worktree string, extraEnv []string, args ...string) ([]byte, error) {
	out, truncated, err := m.runGitCapped(ctx, gitDir, worktree, extraEnv, filetxn.MaxFileBytes, args...)
	if err == nil && truncated {
		err = fmt.Errorf("git output exceeded %d bytes", filetxn.MaxFileBytes)
	}
	return out, err
}
func (m *SnapshotManager) runGitCapped(ctx context.Context, gitDir, worktree string, extraEnv []string, limit int, args ...string) ([]byte, bool, error) {
	baseArgs := []string{"--git-dir=" + gitDir, "--work-tree=" + worktree}
	baseArgs = append(baseArgs, args...)
	cmd := quietCommandContext(ctx, "git", baseArgs...)
	cmd.Dir = worktree
	env := append(os.Environ(),
		"GIT_TERMINAL_PROMPT=0",
		"LC_ALL=C",
	)
	env = append(env, extraEnv...)
	cmd.Env = env
	stdout, stderr := newSnapshotBuffer(limit), newSnapshotBuffer(16<<10)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return nil, stdout.truncated, fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), stdout.truncated, nil
}

// Capture records the current working tree into a content-addressed git tree SHA.
// Best-effort: returns "" if git is missing or worktree is unsuitable (e.g. "/").
func (m *SnapshotManager) Capture(ctx context.Context, worktree string) string {
	tree, _ := m.CaptureChecked(ctx, worktree)
	return tree
}

func (m *SnapshotManager) CaptureChecked(ctx context.Context, worktree string) (string, error) {
	return m.CaptureConfigured(ctx, worktree, nil)
}

func (m *SnapshotManager) CaptureConfigured(ctx context.Context, worktree string, options *SnapshotOptions) (string, error) {
	if m == nil || m.BaseDir == "" || worktree == "" || worktree == "/" {
		return "", fmt.Errorf("此工作目录未启用快照")
	}
	unlock := m.lock(worktree)
	defer unlock()

	policy := options.resolved()
	cctx, cancel := context.WithTimeout(ctx, time.Duration(policy.TimeoutSeconds)*time.Second)
	defer cancel()

	if store := m.protected(worktree); store != nil {
		files, _, err := m.protectedSelection(cctx, worktree, policy)
		if err != nil {
			return "", err
		}
		return store.capture(cctx, worktree, files, policy)
	}
	gitDir, err := m.ensureRepo(cctx, worktree)
	if err != nil {
		return "", err
	}
	tree, err := m.captureBounded(cctx, gitDir, worktree, policy)
	return tree, err
}

// Diff returns structured per-file diffs between two captured tree SHAs.
func (m *SnapshotManager) Diff(ctx context.Context, worktree, fromTree, toTree string) ([]FileDiff, error) {
	if m == nil || m.BaseDir == "" || fromTree == "" || toTree == "" || fromTree == toTree {
		return nil, nil
	}
	unlock := m.lock(worktree)
	defer unlock()

	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	if store := m.protected(worktree); store != nil {
		return store.pair(cctx, fromTree, toTree)
	}
	gitDir, err := m.ensureRepo(cctx, worktree)
	if err != nil {
		return nil, err
	}

	numstatOut, err := m.runGit(cctx, gitDir, worktree, nil, "diff-tree", "-r", "--numstat", "-z", "--no-renames", fromTree, toTree)
	if err != nil {
		return nil, err
	}
	statusOut, err := m.runGit(cctx, gitDir, worktree, nil, "diff-tree", "-r", "--name-status", "-z", "--no-renames", fromTree, toTree)
	if err != nil {
		return nil, err
	}

	statusMap := map[string]string{}
	statusFields := strings.Split(string(statusOut), "\x00")
	for i := 0; i+1 < len(statusFields); i += 2 {
		st := "modified"
		switch statusFields[i] {
		case "A":
			st = "added"
		case "D":
			st = "deleted"
		}
		statusMap[statusFields[i+1]] = st
	}

	var diffs []FileDiff
	for _, line := range strings.Split(string(numstatOut), "\x00") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		add, _ := strconv.Atoi(parts[0])
		del, _ := strconv.Atoi(parts[1])
		file := parts[2]
		st := statusMap[file]
		if st == "" {
			st = "modified"
		}
		diffs = append(diffs, FileDiff{
			File:      file,
			Additions: add,
			Deletions: del,
			Status:    st,
		})
		if len(diffs) > 128 {
			return nil, fmt.Errorf("快照差异超过 128 个文件事务预算")
		}
	}
	// Same Git tree order as numstat; one bounded process supplies all patches.
	patches, truncated, err := m.runGitCapped(cctx, gitDir, worktree, nil, 2<<20, "diff-tree", "-p", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", "-U3", fromTree, toTree)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(string(patches), "\ndiff --git ")
	for i := range diffs {
		patch := "...[diff omitted: output budget exceeded]"
		if i < len(parts) && parts[i] != "" {
			patch = parts[i]
			if i > 0 {
				patch = "diff --git " + patch
			}
			if len(patch) > 16<<10 {
				patch = patch[:16<<10] + "\n...[diff truncated]"
			}
			if truncated && i == len(parts)-1 {
				patch += "\n...[diff truncated]"
			}
		}
		diffs[i].Patch = patch
	}
	return diffs, nil
}

// RestoreFiles restores each relative file path in fileToTree back to its state in that tree
// (removing files that did not exist in their target tree).
func (m *SnapshotManager) RestoreFiles(ctx context.Context, worktree string, fileToTree map[string]string) error {
	if m == nil || m.BaseDir == "" || len(fileToTree) == 0 {
		return nil
	}
	if m.protected(worktree) != nil {
		return fmt.Errorf("加密快照仅允许经过当前文件校验的事务回退")
	}
	unlock := m.lock(worktree)
	defer unlock()

	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	gitDir, err := m.ensureRepo(cctx, worktree)
	if err != nil {
		return err
	}
	cleanWorktree := filepath.Clean(worktree)
	root, err := os.OpenRoot(cleanWorktree)
	if err != nil {
		return err
	}
	defer root.Close()
	// Share commit admission with write/edit/apply_patch. os.Root additionally
	// prevents a replaced parent symlink from redirecting writes out of scope.
	toolMutationMu.Lock()
	defer toolMutationMu.Unlock()
	if err := filetxn.CheckReady(); err != nil {
		return err
	}

	for relFile, treeSHA := range fileToTree {
		if err := cctx.Err(); err != nil {
			return err
		}
		if treeSHA == "" {
			continue
		}
		cleanRel := filepath.Clean(filepath.FromSlash(relFile))
		if cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, ".."+string(filepath.Separator)) || filepath.IsAbs(cleanRel) {
			return fmt.Errorf("restore path escapes worktree: %s", relFile)
		}

		// Check if the file existed in treeSHA
		gitRel := filepath.ToSlash(cleanRel)
		lsOut, err := m.runGit(cctx, gitDir, worktree, nil, "--literal-pathspecs", "ls-tree", treeSHA, "--", gitRel)
		if err != nil {
			return err
		}
		if len(bytes.TrimSpace(lsOut)) == 0 {
			// File was newly created after treeSHA -> remove it
			if err := root.Remove(cleanRel); err != nil && !os.IsNotExist(err) {
				return err
			}
			continue
		}
		// File existed in treeSHA -> extract blob directly so we don't clobber unrelated index entries
		blobOut, err := m.runGit(cctx, gitDir, worktree, nil, "show", treeSHA+":"+gitRel)
		if err != nil {
			return err
		}
		if err := root.MkdirAll(filepath.Dir(cleanRel), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		fields := strings.Fields(string(lsOut))
		if len(fields) == 0 || (fields[0] != "100644" && fields[0] != "100755") {
			return fmt.Errorf("restore requires a regular file in snapshot: %s", relFile)
		}
		if fields[0] == "100755" {
			mode = 0o755
		}
		if err := restoreAtomic(root, cleanRel, blobOut, mode); err != nil {
			return err
		}
	}
	return nil
}

// Rename replaces the final directory entry rather than following a symlink.
// Every operation uses the same traversal-safe root, including temp cleanup.
func restoreAtomic(root *os.Root, rel string, data []byte, mode os.FileMode) error {
	tmp := filepath.Join(filepath.Dir(rel), ".aurora-ai-"+NewID("restore"))
	f, err := root.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	defer root.Remove(tmp)
	_, err = f.Write(data)
	if err == nil {
		err = f.Chmod(mode)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return root.Rename(tmp, rel)
}
