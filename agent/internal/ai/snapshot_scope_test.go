//go:build linux || windows

package ai

import (
	"context"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSnapshotStoreBudgetUsesDeduplicatedObjects(t *testing.T) {
	work := t.TempDir()
	extensionFile(t, work, "source.txt", strings.Repeat("repeated source content\n", 30000))
	m := NewSnapshotManager(t.TempDir())
	ctx := context.Background()
	first, err := m.CaptureChecked(ctx, work)
	if err != nil {
		t.Fatal(err)
	}
	size, err := m.storeBytes(ctx, m.shadowGitDir(work), work)
	if err != nil {
		t.Fatal(err)
	}
	policy := &SnapshotOptions{MaxStoreBytes: int(size) + (16 << 10)}
	if again, err := m.CaptureConfigured(ctx, work, policy); err != nil || again != first {
		t.Fatal("unchanged content was charged as new storage", again, err)
	}
	noise := make([]byte, 64<<10)
	rand.New(rand.NewSource(7)).Read(noise)
	path := filepath.Join(work, "new.bin")
	if err := os.WriteFile(path, noise, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.CaptureConfigured(ctx, work, policy); err == nil || !strings.Contains(err.Error(), "实际占用") {
		t.Fatal("actual new objects did not enforce configured storage budget", err)
	}
	after, err := os.ReadFile(path)
	if err != nil || string(after) != string(noise) {
		t.Fatal("storage failure changed workspace content", err)
	}
}

func TestSnapshotRealGitScopeIgnoresAndTrackedDeletedFiles(t *testing.T) {
	root := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v %v %s", args, err, out)
		}
	}
	git("init", "-q")
	extensionFile(t, root, ".gitignore", "ignored/\n*.log\n")
	extensionFile(t, root, ".git/info/exclude", "private.txt\n")
	extensionFile(t, root, "pkg/source.txt", "before")
	extensionFile(t, root, "pkg/tracked.log", "tracked despite ignore")
	extensionFile(t, root, "outside.txt", "outside scope")
	git("add", "-f", "pkg/source.txt", "pkg/tracked.log", "outside.txt")
	indexBefore, _ := os.ReadFile(filepath.Join(root, ".git", "index"))
	extensionFile(t, root, "pkg/ignored/file.txt", "ignored by ancestor")
	extensionFile(t, root, "pkg/private.txt", "ignored by real info/exclude")
	extensionFile(t, root, "pkg/nested/node_modules/dependency.txt", "dependency")
	large := filepath.Join(root, "pkg", "huge.bin")
	f, err := os.Create(large)
	if err != nil {
		t.Fatal(err)
	}
	f.Truncate(3 << 20)
	f.Close()
	m := NewSnapshotManager(t.TempDir())
	work := filepath.Join(root, "pkg")
	first, err := m.CaptureConfigured(context.Background(), work, &SnapshotOptions{MaxFiles: 2})
	if err != nil {
		t.Fatal(err)
	}
	out, err := m.runGit(context.Background(), m.shadowGitDir(work), work, nil, "ls-tree", "-r", "--name-only", first)
	if err != nil || string(out) != "source.txt\ntracked.log\n" {
		t.Fatal(string(out), err)
	}
	os.Remove(filepath.Join(work, "source.txt"))
	extensionFile(t, work, "new.txt", "new")
	next, err := m.CaptureConfigured(context.Background(), work, &SnapshotOptions{MaxFiles: 2})
	if err != nil {
		t.Fatal(err)
	}
	diff, err := m.Diff(context.Background(), work, first, next)
	if err != nil || len(diff) != 2 {
		t.Fatal(diff, err)
	}
	indexAfter, _ := os.ReadFile(filepath.Join(root, ".git", "index"))
	if string(indexBefore) != string(indexAfter) {
		t.Fatal("snapshot wrote real index")
	}
	for _, d := range diff {
		if strings.Contains(d.File, "..") {
			t.Fatal(d)
		}
	}
}

func TestSnapshotLargeSourceTreeAboveOldCountLimit(t *testing.T) {
	if testing.Short() {
		t.Skip("large-tree regression")
	}
	work := t.TempDir()
	for i := 0; i < 20001; i++ {
		name := filepath.Join(work, NewID("source")+".txt")
		if err := os.WriteFile(name, []byte{}, 0600); err != nil {
			t.Fatal(err)
		}
	}
	m := NewSnapshotManager(t.TempDir())
	tree, err := m.CaptureChecked(context.Background(), work)
	if err != nil || tree == "" {
		t.Fatal("large source project still blocked", err)
	}
}
