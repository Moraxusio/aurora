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
)

// SnapshotManager implements OpenCode's zero-pollution shadow-git snapshot system.
// It maintains a bare git directory under <StateDir>/ai/snapshots/<hash> while
// pointing GIT_WORK_TREE at the workspace folder, so capturing trees and restoring
// files never touches or dirties the user's real .git/index or commit history.
type SnapshotManager struct {
	BaseDir string
	mu      sync.Mutex
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
	gitDir := m.shadowGitDir(worktree)
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
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("git %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

// Capture records the current working tree into a content-addressed git tree SHA.
// Best-effort: returns "" if git is missing or worktree is unsuitable (e.g. "/").
func (m *SnapshotManager) Capture(ctx context.Context, worktree string) string {
	if m == nil || m.BaseDir == "" || worktree == "" || worktree == "/" {
		return ""
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	gitDir, err := m.ensureRepo(cctx, worktree)
	if err != nil {
		return ""
	}
	idxFile := filepath.Join(gitDir, "index.aurora")
	env := []string{"GIT_INDEX_FILE=" + idxFile}

	// Stage tracked + untracked (respecting .gitignore, skipping nested .git repos & giant binaries > 4 MiB via clean excludes)
	// Using `git add --all --ignore-errors` on the shadow index.
	_, err = m.runGit(cctx, gitDir, worktree, env,
		"add", "--all", "--ignore-errors",
		"--", ".",
		":(exclude).git",
		":(exclude)node_modules",
		":(exclude).dart_tool",
		":(exclude)build",
		":(exclude)target",
	)
	if err != nil {
		return ""
	}
	out, err := m.runGit(cctx, gitDir, worktree, env, "write-tree")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Diff returns structured per-file diffs between two captured tree SHAs.
func (m *SnapshotManager) Diff(ctx context.Context, worktree, fromTree, toTree string) ([]FileDiff, error) {
	if m == nil || m.BaseDir == "" || fromTree == "" || toTree == "" || fromTree == toTree {
		return nil, nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	gitDir, err := m.ensureRepo(cctx, worktree)
	if err != nil {
		return nil, err
	}

	numstatOut, err := m.runGit(cctx, gitDir, worktree, nil, "diff-tree", "-r", "--numstat", "--no-renames", fromTree, toTree)
	if err != nil {
		return nil, err
	}
	statusOut, err := m.runGit(cctx, gitDir, worktree, nil, "diff-tree", "-r", "--name-status", "--no-renames", fromTree, toTree)
	if err != nil {
		return nil, err
	}

	statusMap := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(statusOut)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) == 2 {
			st := "modified"
			switch parts[0] {
			case "A":
				st = "added"
			case "D":
				st = "deleted"
			}
			statusMap[parts[1]] = st
		}
	}

	var diffs []FileDiff
	for _, line := range strings.Split(strings.TrimSpace(string(numstatOut)), "\n") {
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
		var patch string
		if pOut, err := m.runGit(cctx, gitDir, worktree, nil, "diff-tree", "-p", "--no-renames", "-U3", fromTree, toTree, "--", file); err == nil {
			patch = string(pOut)
			if len(patch) > 16*1024 {
				patch = patch[:16*1024] + "\n...[diff truncated]"
			}
		}
		diffs = append(diffs, FileDiff{
			File:      file,
			Additions: add,
			Deletions: del,
			Status:    st,
			Patch:     patch,
		})
	}
	return diffs, nil
}

// RestoreFiles restores each relative file path in fileToTree back to its state in that tree
// (removing files that did not exist in their target tree).
func (m *SnapshotManager) RestoreFiles(ctx context.Context, worktree string, fileToTree map[string]string) error {
	if m == nil || m.BaseDir == "" || len(fileToTree) == 0 {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	gitDir, err := m.ensureRepo(cctx, worktree)
	if err != nil {
		return err
	}
	cleanWorktree := filepath.Clean(worktree)

	for relFile, treeSHA := range fileToTree {
		if treeSHA == "" {
			continue
		}
		cleanRel := filepath.Clean(filepath.FromSlash(relFile))
		if strings.HasPrefix(cleanRel, "..") || filepath.IsAbs(cleanRel) {
			return fmt.Errorf("restore path escapes worktree: %s", relFile)
		}
		absTarget := filepath.Join(cleanWorktree, cleanRel)
		if !strings.HasPrefix(absTarget, cleanWorktree+string(filepath.Separator)) && absTarget != cleanWorktree {
			return fmt.Errorf("restore path escapes worktree: %s", relFile)
		}

		// Check if the file existed in treeSHA
		gitRel := filepath.ToSlash(cleanRel)
		lsOut, err := m.runGit(cctx, gitDir, worktree, nil, "ls-tree", treeSHA, "--", gitRel)
		if err != nil {
			return err
		}
		if len(bytes.TrimSpace(lsOut)) == 0 {
			// File was newly created after treeSHA -> remove it
			_ = os.Remove(absTarget)
			continue
		}
		// File existed in treeSHA -> extract blob directly so we don't clobber unrelated index entries
		blobOut, err := m.runGit(cctx, gitDir, worktree, nil, "show", treeSHA+":"+gitRel)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(absTarget), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		fields := strings.Fields(string(lsOut))
		if len(fields) > 0 && strings.HasSuffix(fields[0], "755") {
			mode = 0o755
		}
		if err := os.WriteFile(absTarget, blobOut, mode); err != nil {
			return err
		}
	}
	return nil
}
