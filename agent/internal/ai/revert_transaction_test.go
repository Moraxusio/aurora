//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"aurora3/internal/wire"
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

func TestReviewedRevertNeverRestoresUnselectedConcurrentSave(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git unavailable")
	}
	root := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}}
	e.init()
	ctx := context.Background()
	write := func(name, value string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("ai.txt", "before")
	write("manual.txt", "original")
	start := e.snapshots.Capture(ctx, root)
	write("ai.txt", "tool update")
	write("manual.txt", "independent save")
	end := e.snapshots.Capture(ctx, root)
	diffs, err := e.snapshots.Diff(ctx, root, start, end)
	if err != nil || len(diffs) != 2 {
		t.Fatalf("snapshot did not include both edits: %v %v", diffs, err)
	}
	session := &Session{ID: "review", Root: "work", Workdir: "/", Messages: []Message{
		{ID: "prompt", Role: "user"},
		{ID: "answer", Role: "assistant", Snapshot: &StepSnapshot{Start: start, End: end, Files: diffs}},
	}}
	e.sessions[session.ID] = session
	if err := persistFixture(e, session); err != nil {
		t.Fatal(err)
	}
	service := svc{e}
	scope := json.RawMessage(`{"session_id":"review","message_id":"prompt"}`)
	if _, err := service.opRevert(ctx, scope); wire.CodeOf(err) != wire.CodeBadRequest {
		t.Fatalf("old request could restore all files: %v", err)
	}
	res, err := service.opRevertPreview(ctx, scope)
	if err != nil {
		t.Fatal(err)
	}
	preview := res.(revertPreview)
	if len(preview.Paths) != 2 || preview.Paths[0] != "ai.txt" || preview.Paths[1] != "manual.txt" {
		t.Fatalf("bad preview: %+v", preview)
	}
	run := func(revision string, paths []string) (any, error) {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"session_id": "review", "message_id": "prompt", "files": true,
			"review": revertReview{Revision: revision, Paths: paths}})
		return service.opRevert(ctx, raw)
	}
	if _, err := run("outdated", []string{"ai.txt"}); wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("stale revision accepted: %v", err)
	}
	if _, err := run(preview.Revision, []string{"unlisted.txt"}); wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("unreviewed path accepted: %v", err)
	}
	res, err = run(preview.Revision, []string{"ai.txt"})
	if err != nil || res.(map[string]any)["restored_files"] != 1 {
		t.Fatalf("reviewed revert: %v %v", res, err)
	}
	for name, want := range map[string]string{"ai.txt": "before", "manual.txt": "independent save"} {
		if got, err := os.ReadFile(filepath.Join(root, name)); err != nil || string(got) != want {
			t.Fatalf("%s: %q %v", name, got, err)
		}
	}
}
