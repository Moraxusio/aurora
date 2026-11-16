//go:build linux || windows

package ai

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func auditSession(messages int) *Session {
	s := &Session{ID: "ses_audit", Title: "Persistence benchmark", Root: "home", Workdir: "/", Agent: "build"}
	for i := 0; i < messages; i++ {
		s.Messages = append(s.Messages, Message{
			ID: fmt.Sprintf("msg_%06d", i), SessionID: s.ID, Role: "assistant",
			Parts: []Part{
				{Type: "tool-call", ToolName: "read", ToolCallID: fmt.Sprint(i), Input: json.RawMessage(`{"path":"src/main.go"}`)},
				{Type: "tool-result", ToolCallID: fmt.Sprint(i), Output: strings.Repeat("source line\n", 360)},
			},
		})
	}
	return s
}

func persistFixture(e *Env, s *Session) error {
	e.init()
	e.mu.Lock()
	defer e.mu.Unlock()
	e.sessions[s.ID] = s
	return e.persistSessionLocked(s)
}

// Includes the real atomic write/fsync path, not just JSON encoding.
func BenchmarkAuditPersistSession(b *testing.B) {
	for _, count := range []int{100, 1000} {
		b.Run(fmt.Sprintf("messages_%d", count), func(b *testing.B) {
			e := &Env{StateDir: b.TempDir()}
			s := auditSession(count)
			if err := persistFixture(e, s); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				e.mu.Lock()
				err := e.persistSessionLocked(s)
				e.mu.Unlock()
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func TestPersistenceRejectsInvalidJSONWithoutReplacingCheckpoint(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	s := auditSession(1)
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(e.sessionsDir(), s.ID+".json")
	before, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	s.Messages[0].Parts[0].Input = json.RawMessage(`{"unfinished":`)
	if err := persistFixture(e, s); err == nil {
		t.Fatal("invalid state must fail instead of replacing history with an empty session")
	}
	after, err := os.ReadFile(target)
	if err != nil || string(after) != string(before) {
		t.Fatalf("checkpoint changed on encoding failure: %v", err)
	}
}

func TestPersistenceRetainsJSONPrivacyAndEmptyMessages(t *testing.T) {
	e := &Env{StateDir: t.TempDir()}
	s := &Session{ID: "ses_privacy", Inbox: []InboxItem{{ID: "inbox", Provider: ProviderConfig{APIKey: "secret-key"}}}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(e.sessionsDir(), s.ID+".json")
	data, err := os.ReadFile(target)
	if err != nil || !strings.Contains(string(data), `"messages":[]`) || strings.Contains(string(data), "secret-key") {
		t.Fatalf("empty messages/privacy: %s, %v", data, err)
	}
	s.Messages = []Message{{Parts: []Part{{Type: "image", AttachmentID: "ref", DataURL: "secret-media"}}}}
	if err := persistFixture(e, s); err != nil {
		t.Fatal(err)
	}
	reopened := &Env{StateDir: e.StateDir}
	loaded, _, _, loadErr := reopened.GetSession(s.ID)
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	data, err = json.Marshal(loaded)
	if err != nil || strings.Contains(string(data), "secret-media") || !strings.Contains(string(data), `"attachment_id":"ref"`) {
		t.Fatalf("media reference/privacy: %s, %v", data, err)
	}
	if s.Messages[0].Parts[0].DataURL != "secret-media" || s.Inbox[0].Provider.APIKey != "secret-key" {
		t.Fatal("persistence mutated live request data")
	}
}
