//go:build linux || windows

package ai

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSnapshotBudgetsPreserveFilesAndGCReferencedTrees(t *testing.T) {
	m, work, first := auditSnapshot(t)
	ctx := context.Background()
	path := filepath.Join(work, "large")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.Truncate(snapshotFileMax + 1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := m.CaptureChecked(ctx, work); err == nil {
		t.Fatal("oversized file captured")
	}
	if info, _ := os.Stat(path); info.Size() != snapshotFileMax+1 {
		t.Fatal("capture changed source")
	}
	os.Remove(path)
	extensionFile(t, work, "sub/file.txt", "second")
	second, err := m.CaptureChecked(ctx, work)
	if err != nil {
		t.Fatal(err)
	}
	extensionFile(t, work, "sub/file.txt", "third")
	third, err := m.CaptureChecked(ctx, work)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Prune(ctx, work, map[string]bool{first: true, third: true}); err != nil {
		t.Fatal(err)
	}
	gitDir := m.shadowGitDir(work)
	for _, tree := range []string{first, third} {
		if _, err := m.runGit(ctx, gitDir, work, nil, "cat-file", "-e", tree); err != nil {
			t.Fatal("referenced snapshot lost", err)
		}
	}
	if _, err := m.runGit(ctx, gitDir, work, nil, "cat-file", "-e", second); err == nil {
		t.Fatal("unreferenced snapshot not collected")
	}
	if b, _ := os.ReadFile(filepath.Join(work, "sub/file.txt")); string(b) != "third" {
		t.Fatal("GC changed workspace")
	}
}
func TestSnapshotWorkspaceLocksUnicodeDiffAndBoundedOutput(t *testing.T) {
	m, work, first := auditSnapshot(t)
	other := t.TempDir()
	unlock := m.lock(work)
	done := make(chan struct{})
	go func() { release := m.lock(other); release(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("unrelated workspace blocked")
	}
	unlock()
	extensionFile(t, work, "中文 space.txt", strings.Repeat("added\n", 20000))
	extensionFile(t, work, "sub/file.txt", "changed\n")
	next, err := m.CaptureChecked(context.Background(), work)
	if err != nil {
		t.Fatal(err)
	}
	diffs, err := m.Diff(context.Background(), work, first, next)
	if err != nil {
		t.Fatal(err)
	}
	if len(diffs) != 2 {
		t.Fatal(diffs)
	}
	for _, diff := range diffs {
		if len(diff.Patch) > 17<<10 {
			t.Fatal("patch budget exceeded")
		}
		if diff.File == "中文 space.txt" && (diff.Status != "added" || diff.Additions != 20000) {
			t.Fatal(diff)
		}
	}
	b := newSnapshotBuffer(10)
	if n, err := b.Write([]byte(strings.Repeat("x", 10000))); err != nil || n != 10000 || b.Len() != 10 || !b.truncated {
		t.Fatal(n, err, b.Len())
	}
}
