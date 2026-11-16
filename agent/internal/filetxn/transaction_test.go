package filetxn

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func fixture(t *testing.T, root string) []Change {
	t.Helper()
	var out []Change
	for _, name := range []string{"first.txt", "second.txt", "session.json"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("before "+name), 0o600); err != nil {
			t.Fatal(err)
		}
		out = append(out, Change{Root: root, Path: name,
			Before: State{Exists: true, Data: []byte("before " + name)},
			After:  State{Exists: true, Data: []byte("after " + name), Mode: 0o600}})
	}
	return out
}

func assertFiles(t *testing.T, root, prefix string) {
	t.Helper()
	for _, name := range []string{"first.txt", "second.txt", "session.json"} {
		b, err := os.ReadFile(filepath.Join(root, name))
		if err != nil || string(b) != prefix+" "+name {
			t.Fatalf("%s: %q, %v", name, b, err)
		}
	}
}

func TestBatchChecksEveryVersionBeforeMutation(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	batch := fixture(t, root)
	batch[2].Before.Data = []byte("stale")
	if err := New(state, []string{root}).Commit(context.Background(), batch); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected conflict: %v", err)
	}
	assertFiles(t, root, "before")
}

func TestTransactionPreflightsSuppliedByteBudgetBeforeDiskReads(t *testing.T) {
	data := make([]byte, 1<<20)
	var changes []Change
	for i := 0; i <= MaxTransactionBytes/(2*len(data)); i++ {
		changes = append(changes, Change{Root: "missing-root", Path: fmt.Sprint(i),
			Before: State{Exists: true, Data: data}, After: State{Exists: true, Data: data}})
	}
	err := New(t.TempDir(), nil).Commit(context.Background(), changes)
	if err == nil || !strings.Contains(err.Error(), "byte budget exceeded") {
		t.Fatal("oversized batch reached disk reads", err)
	}
}

func TestCancellationRollsBackFilesAndCheckpoint(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	batch := fixture(t, root)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := New(state, []string{root})
	m.afterApply = func(int) error { cancel(); return nil }
	if err := m.Commit(ctx, batch); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	assertFiles(t, root, "before")
	entries, _ := os.ReadDir(m.Directory)
	if len(entries) != 0 {
		t.Fatalf("rollback leaked journal: %v", entries)
	}
}

func TestCrashRecoveryChild(t *testing.T) {
	root := os.Getenv("AURORA_TXN_CRASH_ROOT")
	if root == "" {
		return
	}
	at, _ := strconv.Atoi(os.Getenv("AURORA_TXN_CRASH_AT"))
	m := New(os.Getenv("AURORA_TXN_CRASH_STATE"), []string{root})
	batch := fixture(t, root)
	m.afterApply = func(i int) error {
		if i == at {
			os.Exit(23)
		}
		return nil
	}
	if err := m.Commit(context.Background(), batch); err != nil {
		t.Fatal(err)
	}
	t.Fatal("crash injection was not reached")
}

func TestRecoveryAfterProcessExitAtEachReplacement(t *testing.T) {
	for i := range 3 {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			root, state := t.TempDir(), t.TempDir()
			cmd := exec.Command(os.Args[0], "-test.run=^TestCrashRecoveryChild$")
			cmd.Env = append(os.Environ(), "AURORA_TXN_CRASH_ROOT="+root,
				"AURORA_TXN_CRASH_STATE="+state, "AURORA_TXN_CRASH_AT="+strconv.Itoa(i))
			output, err := cmd.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 23 {
				t.Fatalf("child did not exit mid-commit: %v, %s", err, output)
			}
			m := New(state, []string{root})
			if err := m.Recover(); err != nil {
				t.Fatal(err)
			}
			assertFiles(t, root, "before")
			if err := m.Recover(); err != nil {
				t.Fatalf("recovery is not idempotent: %v", err)
			}
		})
	}
}

func TestRecoveryRetainsExternalChangesAndJournal(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	batch := fixture(t, root)
	m := New(state, []string{root})
	t.Cleanup(func() { recoveryFaults.Delete(m.Directory) })
	crash := errors.New("process ended")
	m.afterApply = func(int) error { return crash }
	if err := m.Commit(context.Background(), batch); !errors.Is(err, crash) {
		t.Fatal(err)
	}
	path := filepath.Join(root, "first.txt")
	if err := os.WriteFile(path, []byte("user edit after crash"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := m.Recover(); !errors.Is(err, ErrConflict) {
		t.Fatalf("external modification was not detected: %v", err)
	}
	if err := CheckReady(); !errors.Is(err, ErrRecoveryRequired) {
		t.Fatalf("failed startup recovery did not block independent persistence: %v", err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "user edit after crash" {
		t.Fatal("external edit overwritten")
	}
	entries, _ := os.ReadDir(m.Directory)
	if len(entries) != 1 {
		t.Fatal("recovery record lost")
	}
	if err := os.WriteFile(path, []byte("after first.txt"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := m.Recover(); err != nil {
		t.Fatal(err)
	}
	assertFiles(t, root, "before")
}

func TestSuccessfulCommitAndCommittedCleanupDoNotUndo(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	batch := fixture(t, root)
	m := New(state, []string{root})
	if err := m.Commit(context.Background(), batch); err != nil {
		t.Fatal(err)
	}
	assertFiles(t, root, "after")
	id := newID()
	if err := m.writeJournal(id, journal{Format: 1, Changes: batch}); err != nil {
		t.Fatal(err)
	}
	if err := m.markCommitted(id); err != nil {
		t.Fatal(err)
	}
	if err := m.Recover(); err != nil {
		t.Fatal(err)
	}
	assertFiles(t, root, "after")
}

func TestMarkerFailureMustBeDurablyRemovedBeforeRollback(t *testing.T) {
	for _, fault := range []string{"write", "remove", "sync"} {
		t.Run(fault, func(t *testing.T) {
			root, state := t.TempDir(), t.TempDir()
			batch := fixture(t, root)
			m := New(state, []string{root})
			m.afterMarker = func() error { return errors.New("marker fsync failed") }
			if fault == "remove" {
				m.removeMarker = func(*os.Root, string) error { return errors.New("removal denied") }
			}
			if fault == "sync" {
				m.syncJournal = func(*os.Root) error { return errors.New("directory fsync failed") }
			}
			// Independent session persistence checks readiness outside CommitMu
			// while the workspace transaction latches and then repairs a fault.
			stop, stopped := make(chan struct{}), make(chan struct{})
			go func() {
				defer close(stopped)
				for {
					select {
					case <-stop:
						return
					default:
						_ = CheckReady()
					}
				}
			}()
			defer func() { close(stop); <-stopped }()
			err := m.Commit(context.Background(), batch)
			if err == nil {
				t.Fatal("marker failure hidden")
			}
			reopened := New(state, []string{root})
			// Always release the process-wide gate, even when an assertion fails.
			t.Cleanup(func() { _ = reopened.Recover() })
			if fault == "write" {
				assertFiles(t, root, "before")
			} else {
				if !errors.Is(err, ErrRecoveryRequired) {
					t.Fatalf("not latched: %v", err)
				}
				assertFiles(t, root, "after")
				if err := m.Commit(context.Background(), batch); !errors.Is(err, ErrRecoveryRequired) {
					t.Fatalf("uncertain decision admitted more writes: %v", err)
				}
			}
			if err := reopened.Recover(); err != nil {
				t.Fatal(err)
			}
			if fault == "remove" {
				assertFiles(t, root, "after") // intact durable marker selects commit
			} else {
				assertFiles(t, root, "before") // absent marker selects rollback
			}
		})
	}
}

func TestCleanupFailureKeepsCommitDecisionAcrossRecovery(t *testing.T) {
	root, state := t.TempDir(), t.TempDir()
	batch := fixture(t, root)
	m := New(state, []string{root})
	m.syncJournal = func(*os.Root) error { return errors.New("cleanup fsync failed") }
	if err := m.Commit(context.Background(), batch); err != nil {
		t.Fatal(err)
	}
	assertFiles(t, root, "after")
	// Simulate a removed undo record reappearing after an unsuccessful directory
	// sync. Its commit marker must still be present, preventing accidental undo.
	entries, _ := os.ReadDir(m.Directory)
	if len(entries) != 1 {
		t.Fatalf("expected retained marker: %v", entries)
	}
	id := strings.TrimSuffix(entries[0].Name(), ".committed")
	if err := m.writeJournal(id, journal{Format: 1, Changes: batch}); err != nil {
		t.Fatal(err)
	}
	if err := New(state, []string{root}).Recover(); err != nil {
		t.Fatal(err)
	}
	assertFiles(t, root, "after")
}

func TestTransactionRefusesOutOfRootAndEscapingSymlink(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	m := New(t.TempDir(), []string{root})
	for _, c := range []Change{
		{Root: root, Path: "../escape", After: State{Exists: true, Data: []byte("bad")}},
		{Root: outside, Path: "escape", After: State{Exists: true, Data: []byte("bad")}},
	} {
		if err := m.Commit(context.Background(), []Change{c}); err == nil {
			t.Fatal("out-of-root write admitted")
		}
	}
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := m.Commit(context.Background(), []Change{{Root: root, Path: filepath.Join("link", "escape"),
		After: State{Exists: true, Data: []byte("bad")}}}); err == nil {
		t.Fatal("escaping symlink admitted")
	}
	if _, err := os.Stat(filepath.Join(outside, "escape")); !os.IsNotExist(err) {
		t.Fatal("file escaped root")
	}
}
