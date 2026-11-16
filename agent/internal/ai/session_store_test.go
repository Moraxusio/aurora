//go:build linux || windows

package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSessionJournalIncrementalReplayAndCheckpointRotation(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	s := auditSession(1000)
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(e.sessionsDir(), s.ID+".json")
	base, _ := os.ReadFile(path)
	s.Messages = append(s.Messages, Message{ID: "tail", Role: "user", Parts: []Part{{Type: "text", Text: "新输入"}}})
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	unchanged, _ := os.ReadFile(path)
	log, _ := os.ReadFile(filepath.Join(e.sessionsDir(), s.ID+".journal"))
	if !bytes.Equal(base, unchanged) || len(log) > 8192 {
		t.Fatalf("small edit rewrote history: log=%d", len(log))
	}
	for i := 0; i < 65; i++ {
		s.Messages[len(s.Messages)-1].Parts[0].Text = fmt.Sprintf("turn %d", i)
		if err := persistFixture(e, s); err != nil {
			t.Fatal(err)
		}
	}
	reopen := &Env{StateDir: e.StateDir}
	if list := reopen.ListSessions(false); len(list) != 1 || list[0].MessageCount != 1001 {
		t.Fatal(list)
	}
	if reopen.sessions[s.ID].Messages != nil || !reopen.records[s.ID].lazy {
		t.Fatal("startup loaded full history")
	}
	loaded, _, _, err := reopen.GetSession(s.ID)
	if err != nil || loaded.Messages[1000].Parts[0].Text != "turn 64" || len(loaded.Messages) != 1001 {
		t.Fatal("replay", err)
	}
	if loaded.Messages[0].Parts[1].Output != s.Messages[0].Parts[1].Output {
		t.Fatal("old messages lost")
	}
}

func TestSessionJournalTornTailAndCorruptionPreserveEvidence(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	s := &Session{ID: "s", Messages: []Message{{ID: "m", Role: "user", Parts: []Part{{Type: "text", Text: "first"}}}}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	s.Title = "durable"
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(e.sessionsDir(), "s.journal")
	good, _ := os.ReadFile(path)
	torn := append(append([]byte{}, good...), frameSessionDelta([]byte(`{"incomplete":true}`))[:12]...)
	if err := os.WriteFile(path, torn, 0600); err != nil {
		t.Fatal(err)
	}
	reopen := &Env{StateDir: e.StateDir}
	loaded, _, _, err := reopen.GetSession("s")
	if err != nil || loaded.Title != "durable" {
		t.Fatal(loaded.Title, err)
	}
	title := "after recovery"
	if _, err := reopen.UpdateSessionMeta("s", &title, nil); err != nil {
		t.Fatal(err)
	}
	evidence, _ := filepath.Glob(path + ".torn-*")
	if len(evidence) != 1 {
		t.Fatal("missing torn-log evidence")
	}
	saved, _ := os.ReadFile(evidence[0])
	if !bytes.Equal(saved, torn) {
		t.Fatal("torn record overwritten")
	}
	corrupt, _ := os.ReadFile(path)
	corrupt[10] ^= 1
	if err := os.WriteFile(path, corrupt, 0600); err != nil {
		t.Fatal(err)
	}
	blocked := &Env{StateDir: e.StateDir}
	if _, _, _, err := blocked.GetSession("s"); err == nil {
		t.Fatal("corrupt journal silently replayed")
	}
	if _, err := blocked.UpdateSessionMeta("s", &title, nil); err == nil {
		t.Fatal("corrupt record overwritten")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(after, corrupt) {
		t.Fatal("bad evidence changed")
	}
	if list := blocked.ListSessions(false); len(list) != 1 || list[0].StorageError == "" {
		t.Fatal("corrupt record hidden", list)
	}
}

func TestSessionIndependentPersistenceAndSameSessionOrdering(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	for _, id := range []string{"a", "b"} {
		if err := persistFixture(e, &Session{ID: id, Title: "before"}); err != nil {
			t.Fatal(err)
		}
	}
	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	e.beforeSessionWrite = func(id string) error {
		if id == "a" {
			select {
			case <-entered:
			default:
				close(entered)
			}
			<-release
		}
		return nil
	}
	first := make(chan error, 1)
	title := "first"
	go func() { _, err := e.UpdateSessionMeta("a", &title, nil); first <- err }()
	<-entered
	other := make(chan error, 1)
	go func() { _, err := e.UpdateSessionMeta("b", &title, nil); other <- err }()
	select {
	case err := <-other:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("one session blocked unrelated persistence")
	}
	if len(e.ListSessions(false)) != 2 {
		t.Fatal("listing blocked")
	}
	second := make(chan error, 1)
	go func() { next := "second"; _, err := e.UpdateSessionMeta("a", &next, nil); second <- err }()
	select {
	case <-second:
		t.Fatal("same-session write overtook pending commit")
	default:
	}
	close(release)
	if err := <-first; err != nil {
		t.Fatal(err)
	}
	if err := <-second; err != nil {
		t.Fatal(err)
	}
	got, _, _, err := (&Env{StateDir: e.StateDir}).GetSession("a")
	if err != nil || got.Title != "second" {
		t.Fatal(got.Title, err)
	}
}

func TestSessionIndexLazySearchCacheAndAttachmentReferences(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	e.init()
	attachment := uploadFixture(t, e, "shared.txt", []byte("shared immutable data"))
	for i := 0; i < 12; i++ {
		s := &Session{ID: fmt.Sprintf("s%d", i), Title: "fixture", UpdatedAt: int64(i), Messages: []Message{
			{ID: "text", Role: "user", Parts: []Part{{Type: "text", Text: fmt.Sprintf("search 中文 %d", i)}, {Type: "file", AttachmentID: attachment.ID}}},
		}}
		if err := persistFixture(e, s); err != nil {
			t.Fatal(err)
		}
	}
	reopen := &Env{StateDir: e.StateDir}
	reopen.init()
	for _, s := range reopen.sessions {
		if s.Messages != nil {
			t.Fatal("eager history")
		}
	}
	hits, err := reopen.searchSessionsContext(context.Background(), "search 中文", 3)
	if err != nil || len(hits) != 3 || hits[0].SessionID != "s11" {
		t.Fatal(hits, err)
	}
	for _, r := range reopen.records {
		if !r.lazy {
			t.Fatal("search filled interactive cache")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := reopen.searchSessionsContext(ctx, "search", 3); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	for i := 0; i < 12; i++ {
		if _, _, _, err := reopen.GetSession(fmt.Sprintf("s%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	count := 0
	for _, r := range reopen.records {
		if !r.lazy {
			count++
		}
	}
	if count > sessionCacheMax {
		t.Fatal("unbounded cache", count)
	}
	if err := reopen.DeleteSession("s0"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(e.attachmentDir(), attachment.ID+".bin")); err != nil {
		t.Fatal("lazy reference lost", err)
	}
	for i := 1; i < 12; i++ {
		if err := reopen.DeleteSession(fmt.Sprintf("s%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(filepath.Join(e.attachmentDir(), attachment.ID+".bin")); !os.IsNotExist(err) {
		t.Fatal("unused attachment not collected")
	}
}

func TestSnapshotServiceKeepsLazyReferencesAndBlocksUnknownRecords(t *testing.T) {
	m, work, first := auditSnapshot(t)
	e := &Env{StateDir: filepath.Dir(filepath.Dir(m.BaseDir)), Roots: []Root{{ID: "work", Path: work}}}
	e.init()
	e.snapshots = m
	s := &Session{ID: "s", Root: "work", Workdir: "/", Messages: []Message{{ID: "m", Snapshot: &StepSnapshot{Start: first, End: first}}}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	extensionFile(t, work, "sub/file.txt", "unreferenced")
	unused, err := m.CaptureChecked(context.Background(), work)
	if err != nil {
		t.Fatal(err)
	}
	extensionFile(t, e.sessionsDir(), "broken.json", "{bad")
	reopen := &Env{StateDir: e.StateDir, Roots: e.Roots}
	args := json.RawMessage(`{"root":"work","workdir":"/"}`)
	if _, err := (svc{reopen}).opPruneSnapshots(context.Background(), args); err == nil {
		t.Fatal("GC ignored corrupt session")
	}
	if _, err := m.runGit(context.Background(), m.shadowGitDir(work), work, nil, "cat-file", "-e", unused); err != nil {
		t.Fatal("GC removed unknown references")
	}
	if err := reopen.DeleteSession("broken"); err != nil {
		t.Fatal(err)
	}
	if _, err := (svc{reopen}).opPruneSnapshots(context.Background(), args); err != nil {
		t.Fatal(err)
	}
	if _, err := m.runGit(context.Background(), m.shadowGitDir(work), work, nil, "cat-file", "-e", first); err != nil {
		t.Fatal("lazy snapshot reference removed")
	}
	if _, err := m.runGit(context.Background(), m.shadowGitDir(work), work, nil, "cat-file", "-e", unused); err == nil {
		t.Fatal("unused tree retained")
	}
	if !reopen.records["s"].lazy {
		t.Fatal("GC loaded body")
	}
	// An orphan journal has unknown references too.
	extensionFile(t, e.sessionsDir(), "orphan.journal", strings.Repeat("x", 8))
	another := &Env{StateDir: e.StateDir, Roots: e.Roots}
	if _, err := (svc{another}).opPruneSnapshots(context.Background(), args); err == nil {
		t.Fatal("orphan journal ignored")
	}
}

func TestSessionRevertTruncatesIncrementalHistoryAtomically(t *testing.T) {
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	s := &Session{ID: "s", Root: "work", Workdir: "/", Messages: []Message{{ID: "keep", Role: "user"}}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	s.Messages = append(s.Messages, Message{ID: "remove", Role: "user"})
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.RevertSession(context.Background(), "s", "remove", false); err != nil {
		t.Fatal(err)
	}
	loaded, _, _, err := (&Env{StateDir: e.StateDir, Roots: e.Roots}).GetSession("s")
	if err != nil || len(loaded.Messages) != 1 || loaded.Messages[0].ID != "keep" {
		t.Fatal("reverted journal replayed", err)
	}
}

func TestSessionIndexCorruptionRebuildsAndReadsDoNotRewrite(t *testing.T) {
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	s := &Session{ID: "s", Title: "real", Root: "work", Workdir: "/", Messages: []Message{{ID: "m", Role: "user", Parts: []Part{{Type: "file", AttachmentID: "referenced"}}}}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(e.sessionsDir(), "s.index")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var disk sessionIndexFile
	if err := json.Unmarshal(data, &disk); err != nil {
		t.Fatal(err)
	}
	disk.Index.Attachments = nil // Valid JSON with damaged references is not trusted.
	damaged, _ := json.Marshal(disk)
	if err := os.WriteFile(path, damaged, 0600); err != nil {
		t.Fatal(err)
	}
	reopened := &Env{StateDir: e.StateDir, Roots: e.Roots}
	reopened.init()
	if got := reopened.records["s"].index.Attachments; len(got) != 1 || got[0] != "referenced" {
		t.Fatal(got)
	}
	stamp, _ := sessionFileStamp(path)
	for i := 0; i < 3; i++ {
		if _, _, err := readSessionDisk(e.sessionsDir(), "s"); err != nil {
			t.Fatal(err)
		}
	}
	after, _ := sessionFileStamp(path)
	if after != stamp {
		t.Fatal("read rewrote derived index")
	}
	if _, _, _, err := reopened.GetSession("s"); err != nil {
		t.Fatal(err)
	}
	title := "outside"
	s.Title = title
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	if _, _, err := reopened.RevertSession(context.Background(), "s", "m", false); err == nil {
		t.Fatal("revert overwrote externally changed session")
	}
	current, _, _, err := (&Env{StateDir: e.StateDir}).GetSession("s")
	if err != nil || current.Title != title {
		t.Fatal(current.Title, err)
	}
}

func TestLargeSessionCanRevertAndDeleteWithinStorageBudget(t *testing.T) {
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	// Exceeds the former 32 MiB transaction limit but fits a valid checkpoint.
	content := strings.Repeat("x", (32<<20)+1)
	s := &Session{ID: "large", Root: "work", Workdir: "/", Messages: []Message{
		{ID: "keep", Role: "assistant", Parts: []Part{{Type: "tool-result", Output: content}}},
	}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	s.Messages = append(s.Messages, Message{ID: "remove", Role: "user"})
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	reverted, _, err := e.RevertSession(context.Background(), s.ID, "remove", false)
	if err != nil || len(reverted.Messages) != 1 || reverted.Messages[0].Parts[0].Output != content {
		t.Fatal("large-session revert", err)
	}
	reopen := &Env{StateDir: e.StateDir, Roots: e.Roots}
	loaded, _, _, err := reopen.GetSession(s.ID)
	if err != nil || len(loaded.Messages) != 1 || loaded.Messages[0].Parts[0].Output != content {
		t.Fatal("large-session replay", err)
	}
	if err := reopen.DeleteSession(s.ID); err != nil {
		t.Fatal("large-session delete", err)
	}
	if got := (&Env{StateDir: e.StateDir}).ListSessions(true); len(got) != 0 {
		t.Fatal("deleted session reappeared", got)
	}
}

func TestSessionDeletePreflightsDescendantBudgetWithoutPartialDeletion(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	for i := 0; i < 172; i++ {
		s := &Session{ID: fmt.Sprintf("s%d", i), ParentID: "s0"}
		if i == 0 {
			s.ParentID = ""
		}
		if err := persistFixture(e, s); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.DeleteSession("s0"); err == nil || !strings.Contains(err.Error(), "请先删除部分子会话") {
		t.Fatal("missing actionable batch limit", err)
	}
	reopen := &Env{StateDir: e.StateDir}
	if got := reopen.ListSessions(true); len(got) != 172 {
		t.Fatal("rejected delete changed the session tree", len(got))
	}
	for i := 1; i <= 4; i++ {
		if err := reopen.DeleteSession(fmt.Sprintf("s%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if err := reopen.DeleteSession("s0"); err != nil {
		t.Fatal("bounded descendant deletion", err)
	}
	if got := (&Env{StateDir: e.StateDir}).ListSessions(true); len(got) != 0 {
		t.Fatal("descendants survived committed deletion", len(got))
	}
}
