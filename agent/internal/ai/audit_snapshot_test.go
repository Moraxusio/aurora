//go:build linux || windows

package ai

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func auditSnapshot(t *testing.T) (*SnapshotManager, string, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git unavailable")
	}
	work := t.TempDir()
	if err := os.Mkdir(filepath.Join(work, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, "sub", "file.txt"), []byte("snapshot"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := NewSnapshotManager(t.TempDir())
	tree := m.Capture(context.Background(), work)
	if tree == "" {
		t.Fatal("capture failed")
	}
	return m, work, tree
}

func TestSnapshotRestoreRejectsEscapingSymlinkParent(t *testing.T) {
	m, work, tree := auditSnapshot(t)
	outside := t.TempDir()
	target := filepath.Join(outside, "file.txt")
	if err := os.WriteFile(target, []byte("outside"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(work, "sub")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(work, "sub")); err != nil {
		t.Skipf("symlink creation unavailable: %v", err)
	}
	err := m.RestoreFiles(context.Background(), work, map[string]string{"sub/file.txt": tree})
	data, readErr := os.ReadFile(target)
	if err == nil || readErr != nil || string(data) != "outside" {
		t.Fatalf("restore followed escaping symlink: err=%v outside=%q read=%v", err, data, readErr)
	}
}

func TestSnapshotRestoreReportsFailedDeletion(t *testing.T) {
	m, work, tree := auditSnapshot(t)
	dir := filepath.Join(work, "new.txt")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "user.txt"), []byte("preserve"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := m.RestoreFiles(context.Background(), work, map[string]string{"new.txt": tree}); err == nil {
		t.Fatal("nonempty directory removal reported success")
	}
}

func TestSnapshotRestoreReplacesFinalSymlinkWithoutTouchingTarget(t *testing.T) {
	m, work, tree := auditSnapshot(t)
	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(outside, []byte("outside"), 0o644); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(work, "sub", "file.txt")
	if err := os.Remove(dest); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, dest); err != nil {
		t.Skipf("symlink creation unavailable: %v", err)
	}
	if err := m.RestoreFiles(context.Background(), work, map[string]string{"sub/file.txt": tree}); err != nil {
		t.Fatal(err)
	}
	a, _ := os.ReadFile(outside)
	b, _ := os.ReadFile(dest)
	if string(a) != "outside" || string(b) != "snapshot" {
		t.Fatalf("outside=%q restored=%q", a, b)
	}
}
