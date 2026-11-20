//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"aurora3/internal/statecrypt"
)

func TestProtectedAIStoreAcrossProcesses(t *testing.T) {
	root := t.TempDir()
	for _, mode := range []string{"write", "reopen", "wrong-key", "missing-key", "corrupt"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestProtectedAIStoreChild$")
		cmd.Env = append(os.Environ(), "AURORA_AI_STORE_TEST_DIR="+root, "AURORA_AI_STORE_TEST_MODE="+mode)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v\n%s", mode, err, out)
		}
	}
}

func TestProtectedAIStoreChild(t *testing.T) {
	root, mode := os.Getenv("AURORA_AI_STORE_TEST_DIR"), os.Getenv("AURORA_AI_STORE_TEST_MODE")
	if root == "" {
		return
	}
	if mode != "missing-key" {
		fill := byte(7)
		if mode == "wrong-key" {
			fill = 8
		}
		codec, err := statecrypt.New(bytes.Repeat([]byte{fill}, statecrypt.KeyBytes))
		if err != nil {
			t.Fatal(err)
		}
		if err := statecrypt.Activate(codec); err != nil {
			t.Fatal(err)
		}
	}
	env := &Env{StateDir: root}
	dir := env.sessionsDir()
	const text = "synthetic private source text"
	const id = "session-fixture"
	path := filepath.Join(dir, id+".journal")
	if mode == "write" {
		s := Session{ID: id, Title: text}
		r, err := saveSessionDisk(dir, &s, nil)
		if err != nil {
			t.Fatal(err)
		}
		s.Messages = []Message{{Role: "user", Parts: []Part{{Type: "text", Text: text}}}}
		if _, err := saveSessionDisk(dir, &s, r); err != nil {
			t.Fatal(err)
		}
		dir := env.attachmentDir()
		if err := checkAttachmentBudget(dir, int64(len(text))); err != nil {
			t.Fatal(err)
		}
		if _, err := saveAttachment(dir, text, "text/plain", []byte(text)); err != nil {
			t.Fatal(err)
		}
		spill := TruncateOutput(strings.Repeat(text+"\n", 3000), filepath.Join(root, "ai", "tool-output"), "head")
		if spill.SavedPath == "" {
			t.Fatal("tool output was not retained")
		}
	}
	log, err := os.ReadFile(path)
	if err != nil || len(log) < 9 {
		t.Fatalf("missing journal: %v", err)
	}
	if mode == "corrupt" {
		log[len(log)-1] ^= 1
		// Recompute the old CRC so the AEAD itself must reject tampering.
		binary.BigEndian.PutUint32(log[4:], crc32.ChecksumIEEE(log[8:]))
		if err := os.WriteFile(path, log, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := filepath.WalkDir(root, func(path string, ent os.DirEntry, err error) error {
		if err != nil || ent.IsDir() {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if bytes.Contains(data, []byte(text)) {
			t.Errorf("plaintext in %s", path)
		}
		if filepath.Ext(path) == ".journal" {
			data = data[8:]
		}
		if !statecrypt.Protected(data) {
			t.Errorf("unprotected record in %s", path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	s, _, err := readSessionDisk(dir, id)
	if mode == "wrong-key" || mode == "missing-key" || mode == "corrupt" {
		if err == nil {
			t.Fatalf("accepted session in %s case", mode)
		}
		if _, err := saveSessionDisk(dir, &Session{ID: id, Title: "replacement"}, nil); err == nil {
			t.Fatal("replaced the unreadable session with a new checkpoint")
		}
		after, readErr := os.ReadFile(path)
		if readErr != nil || !bytes.Equal(after, log) {
			t.Fatal("failed read altered evidence")
		}
		return
	}
	if err != nil || len(s.Messages) != 1 || s.Messages[0].Parts[0].Text != text {
		t.Fatalf("failed to recover session: %v", err)
	}
	if idx, ok := readSessionIndex(dir, id); !ok || idx.Meta.Title != text {
		t.Fatal("failed to recover encrypted index")
	}
	meta, err := filepath.Glob(filepath.Join(env.attachmentDir(), "*.json"))
	if err != nil || len(meta) != 1 {
		t.Fatalf("attachment missing: %v", err)
	}
	attID := strings.TrimSuffix(filepath.Base(meta[0]), ".json")
	data, err := env.loadAttachment(Part{AttachmentID: attID})
	if err != nil || string(data) != text {
		t.Fatalf("failed to recover attachment: %v", err)
	}
	spills, err := filepath.Glob(filepath.Join(root, "ai", "tool-output", "*.txt"))
	if err != nil || len(spills) != 1 {
		t.Fatalf("spill missing: %v", err)
	}
	tc := toolContext{env: env, session: s, rootPath: root, absWorkdir: root}
	check := func(string, string, map[string]any) error { return nil }
	raw, _ := json.Marshal(map[string]any{"path": spills[0], "limit": 1})
	if r := execReadTool(context.Background(), tc, raw, check); r.IsError || !strings.Contains(r.Output, text) {
		t.Fatalf("could not read spill: %+v", r)
	}
	raw, _ = json.Marshal(map[string]any{"path": spills[0], "pattern": text, "literal": true, "limit": 1})
	if r := execGrepTool(context.Background(), tc, raw, check); r.IsError || !strings.Contains(r.Output, text) {
		t.Fatalf("could not search spill: %+v", r)
	}
}

func TestProtectedSnapshotStore(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestProtectedSnapshotStoreChild$")
	cmd.Env = append(os.Environ(), "AURORA_SNAPSHOT_TEST_DIR="+t.TempDir())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
}

func TestProtectedSnapshotStoreChild(t *testing.T) {
	root := os.Getenv("AURORA_SNAPSHOT_TEST_DIR")
	if root == "" {
		return
	}
	codec, err := statecrypt.New(bytes.Repeat([]byte{7}, statecrypt.KeyBytes))
	if err != nil {
		t.Fatal(err)
	}
	if err := statecrypt.Activate(codec); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	state, work := filepath.Join(root, "state"), filepath.Join(root, "work")
	if err := os.Mkdir(work, 0o700); err != nil {
		t.Fatal(err)
	}
	file := "示例.txt"
	const before = "synthetic secret before\n"
	const after = "synthetic secret after\n"
	save := func(value string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(work, file), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	save(before)
	m := NewSnapshotManager(state)
	first, err := m.CaptureChecked(ctx, work)
	if err != nil {
		t.Fatal(err)
	}
	if same, err := m.CaptureChecked(ctx, work); err != nil || same != first {
		t.Fatalf("unchanged snapshot was not deduplicated: %v", err)
	}
	save(after)
	last, err := m.CaptureChecked(ctx, work)
	if err != nil || first == last {
		t.Fatalf("changed snapshot: %v", err)
	}
	var count int
	store := m.protected(work)
	if err := filepath.WalkDir(store.dir, func(path string, ent os.DirEntry, err error) error {
		if err != nil || ent.IsDir() {
			return err
		}
		count++
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !statecrypt.Protected(b) || bytes.Contains(b, []byte(before)) || bytes.Contains(b, []byte(after)) || bytes.Contains(b, []byte(file)) {
			t.Errorf("unprotected snapshot content: %s", path)
		}
		return nil
	}); err != nil || count != 4 {
		t.Fatalf("snapshot artifacts: %d: %v", count, err)
	}
	if _, err := os.Stat(m.shadowGitDir(work)); !os.IsNotExist(err) {
		t.Fatal("source snapshot unexpectedly used a legacy shadow repository")
	}
	m = NewSnapshotManager(state)
	diffs, err := m.Diff(ctx, work, first, last)
	if err != nil || len(diffs) != 1 || diffs[0].File != file || !strings.Contains(diffs[0].Patch, "+synthetic secret after") {
		t.Fatalf("encrypted diff failed: %+v %v", diffs, err)
	}
	plan, err := m.PlanRestore(ctx, work, map[string]string{file: first}, map[string]string{file: last})
	if err != nil || len(plan) != 1 || string(plan[0].Before.Data) != after || string(plan[0].After.Data) != before {
		t.Fatalf("encrypted restore plan failed: %+v %v", plan, err)
	}
	stats, err := m.Prune(ctx, work, map[string]bool{first: true})
	if err != nil || stats["afterBytes"] >= stats["beforeBytes"] {
		t.Fatalf("prune failed: %v %v", stats, err)
	}
	if _, err := m.PlanRestore(ctx, work, map[string]string{file: first}, map[string]string{file: first}); err != nil {
		t.Fatalf("prune lost retained contents: %v", err)
	}
	if _, err := m.Diff(ctx, work, first, last); err == nil {
		t.Fatal("deleted tree remains readable")
	}
}
