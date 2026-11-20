//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"aurora3/internal/statecrypt"
)

func TestCloneLegacySnapshotHistory(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("Git unavailable")
	}
	ctx := context.Background()
	source := t.TempDir()
	projects := t.TempDir()
	work := filepath.Join(projects, "nested")
	if err := os.Mkdir(work, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(work, "示例.txt")
	const before, after = "synthetic original\n", "synthetic change\n"
	write := func(value string) {
		t.Helper()
		if err := os.WriteFile(file, []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := NewSnapshotManager(source)
	spill := filepath.Join(source, "ai", "tool-output", "tool_0123456789abcdef01234567.txt")
	if err := os.MkdirAll(filepath.Dir(spill), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(spill, []byte("synthetic private tool result"), 0o600); err != nil {
		t.Fatal(err)
	}
	write(before)
	first, err := old.CaptureChecked(ctx, work)
	if err != nil {
		t.Fatal(err)
	}
	write(after)
	last, err := old.CaptureChecked(ctx, work)
	if err != nil {
		t.Fatal(err)
	}
	save := func(tree string) {
		t.Helper()
		d := (&Env{StateDir: source}).sessionsDir()
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
		s := Session{ID: "session-fixture", Root: "work", Workdir: "/nested",
			Messages: []Message{{Snapshot: &StepSnapshot{Start: first, End: tree}, Parts: []Part{{
				Type: "tool-result", Output: "Full output saved to: " + spill + "\n",
				Metadata: map[string]any{"saved_path": spill},
			}}}}}
		b, err := json.Marshal(s)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, s.ID+".json"), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	hashes := func(dir string) map[string][32]byte {
		t.Helper()
		out := map[string][32]byte{}
		if err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			b, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			out[path] = sha256.Sum256(b)
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		return out
	}
	codec, err := statecrypt.New(bytes.Repeat([]byte{3}, statecrypt.KeyBytes))
	if err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "clone")
	targetRoot := filepath.Join(dest, "fixture-project")
	targetWork := filepath.Join(targetRoot, "nested")
	clone := func() error {
		return statecrypt.CloneDirectory(source, dest, func(stage string, _ []string) error {
			return CloneLegacyStore(source, stage, codec, CloneWorkspaces{
				Legacy: []Root{{ID: "work", Path: projects}},
				Target: []Root{{ID: "work", Path: targetRoot}}, Final: dest,
			})
		})
	}
	save(strings.Repeat("0", 40))
	sourceRecords := hashes(source)
	if err := clone(); err == nil || !reflect.DeepEqual(sourceRecords, hashes(source)) {
		t.Fatal("missing history was accepted or the original was changed")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("partial clone was published")
	}
	save(last)
	sourceRecords = hashes(source)
	if err := clone(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sourceRecords, hashes(source)) {
		t.Fatal("source state or Git repository was modified")
	}
	b, err := os.ReadFile(filepath.Join(dest, "ai", "sessions", "session-fixture.json"))
	if err != nil {
		t.Fatal(err)
	}
	b, err = codec.Open("ai:checkpoint:session-fixture.json", b)
	if err != nil {
		t.Fatal(err)
	}
	var session Session
	if err := json.Unmarshal(b, &session); err != nil {
		t.Fatal(err)
	}
	snap := session.Messages[0].Snapshot
	if snap.Start == first || snap.End == last {
		t.Fatal("legacy tree IDs remained in the migrated session")
	}
	part := session.Messages[0].Parts[0]
	spillTarget := filepath.Join(dest, "ai", "tool-output", filepath.Base(spill))
	if part.Metadata["saved_path"] != spillTarget || !strings.Contains(part.Output, spillTarget) {
		t.Fatal("migrated tool output still refers to the legacy state")
	}
	sealed, err := os.ReadFile(spillTarget)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := codec.Open("ai:tool-output:"+filepath.Base(spillTarget), sealed)
	if err != nil || string(plain) != "synthetic private tool result" {
		t.Fatal("migrated tool output was not protected and recoverable", err)
	}
	store := newProtectedSnapshots(NewSnapshotManager(dest).BaseDir, targetWork, codec)
	diff, err := store.pair(ctx, snap.Start, snap.End)
	if err != nil || len(diff) != 1 || !strings.Contains(diff[0].Patch, "+synthetic change") {
		t.Fatalf("migrated history cannot show its original diff: %v %v", diff, err)
	}
	changes, err := store.plan(ctx, targetWork, map[string]string{"示例.txt": snap.Start}, map[string]string{"示例.txt": snap.End})
	if err != nil || len(changes) != 1 || string(changes[0].Before.Data) != after || string(changes[0].After.Data) != before {
		t.Fatalf("migrated history cannot plan its original restore: %v %v", changes, err)
	}
	if err := filepath.WalkDir(dest, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		b, err := os.ReadFile(path)
		if err == nil && (!statecrypt.Protected(b) || bytes.Contains(b, []byte(before)) || bytes.Contains(b, []byte(after))) {
			t.Errorf("unprotected data in %s", path)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
}
