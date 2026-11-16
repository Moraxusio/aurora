//go:build linux || windows

package ai

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestRevertIsVersionCheckedAndCheckpointedAsOneBatch(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git unavailable")
	}
	root := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
	e.init()
	ctx := context.Background()
	write := func(name, text string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("one.txt", "original one")
	write("two.txt", "original two")
	start := e.snapshots.Capture(ctx, root)
	write("one.txt", "AI one")
	write("two.txt", "AI two")
	end := e.snapshots.Capture(ctx, root)
	if start == "" || end == "" {
		t.Fatal("snapshots unavailable")
	}
	e.sessions["s"] = &Session{ID: "s", Root: "work", Workdir: "/", Messages: []Message{
		{ID: "prompt", Role: "user"},
		{ID: "answer", Role: "assistant", Snapshot: &StepSnapshot{Start: start, End: end,
			Files: []FileDiff{{File: "one.txt"}, {File: "two.txt"}}}},
	}}
	if err := persistFixture(e, e.sessions["s"]); err != nil {
		t.Fatal(err)
	}
	write("two.txt", "user newer edit")
	if _, _, err := e.RevertSession(ctx, "s", "prompt", true); err == nil {
		t.Fatal("revert overwrote newer user edit")
	}
	one, _ := os.ReadFile(filepath.Join(root, "one.txt"))
	if string(one) != "AI one" || len(e.sessions["s"].Messages) != 2 {
		t.Fatal("failed revert partially changed files or history")
	}
	write("two.txt", "AI two")
	checkpoint := filepath.Join(e.sessionsDir(), "s.json")
	if err := os.Rename(checkpoint, checkpoint+".backup"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(checkpoint, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.RevertSession(ctx, "s", "prompt", true); err == nil {
		t.Fatal("bad checkpoint destination did not fail")
	}
	one, _ = os.ReadFile(filepath.Join(root, "one.txt"))
	if string(one) != "AI one" || len(e.sessions["s"].Messages) != 2 {
		t.Fatal("checkpoint failure changed files or history")
	}
	if err := os.Remove(checkpoint); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(checkpoint+".backup", checkpoint); err != nil {
		t.Fatal(err)
	}
	if _, n, err := e.RevertSession(ctx, "s", "prompt", true); err != nil || n != 2 {
		t.Fatalf("successful revert: count=%d err=%v", n, err)
	}
	one, _ = os.ReadFile(filepath.Join(root, "one.txt"))
	two, _ := os.ReadFile(filepath.Join(root, "two.txt"))
	reopened := &Env{StateDir: e.StateDir, Roots: e.Roots}
	recovered, _, _, err := reopened.GetSession("s")
	if err != nil {
		t.Fatal(err)
	}
	if string(one) != "original one" || string(two) != "original two" || len(recovered.Messages) != 0 {
		t.Fatal("durable batch did not restore both files and session")
	}
}
