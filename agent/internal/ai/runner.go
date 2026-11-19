//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"aurora3/internal/filetxn"
	"aurora3/internal/paths"
)

type activeRun struct {
	cancel            context.CancelFunc
	stopRequested     bool // guarded by Env.mu; cleanup cancellation is not a user stop
	turnCtx           context.Context
	turnCancel        context.CancelFunc
	inbox             []InboxItem
	queued            []InboxItem
	provider          ProviderConfig
	subagentProvider  *ProviderConfig
	subagentPermMode  string
	subagentPermRules []PermissionRule
	meter             *runMeter
}

// Env is the state and dependencies of the "ai" service on the agent.
type Env struct {
	StateDir   string
	Roots      []Root
	Audit      Auditor
	Proxy      func() map[string]string
	AgentProxy func() map[string]string // explicit Aurora node; legacy local Proxy remains the system route

	once               sync.Once
	mu                 sync.Mutex
	sessions           map[string]*Session
	records            map[string]*sessionRecord
	sessionErrors      map[string]error
	sessionIO          map[string]chan struct{}
	storeError         error
	storeClock         uint64
	beforeSessionWrite func(string) error // deterministic disk fault injection
	running            map[string]*activeRun
	maintenance        map[string]context.CancelFunc // exclusive manual compaction/revert
	subs               map[chan StreamEvent]struct{}
	perms              *PermissionGate
	snapshots          *SnapshotManager
	activities         map[string]StreamEvent
	questions          map[string]*pendingQuestion
	recoveryErr        error
	proposalMu         sync.Mutex
	proposalCancels    map[string]context.CancelFunc
}

func (e *Env) init() {
	e.once.Do(func() {
		e.sessions = map[string]*Session{}
		e.records = map[string]*sessionRecord{}
		e.sessionErrors = map[string]error{}
		e.sessionIO = map[string]chan struct{}{}
		e.running = map[string]*activeRun{}
		e.maintenance = map[string]context.CancelFunc{}
		e.subs = map[chan StreamEvent]struct{}{}
		e.perms = NewPermissionGate()
		e.activities = map[string]StreamEvent{}
		e.questions = map[string]*pendingQuestion{}
		e.snapshots = NewSnapshotManager(e.StateDir)
		e.recoveryErr = e.fileTransactions().Recover()
		e.loadSessionIndex()
	})
}

func (e *Env) sessionsDir() string {
	if e.StateDir == "" {
		return ""
	}
	return filepath.Join(e.StateDir, "ai", "sessions")
}

func cloneSession(s *Session) Session {
	b, _ := json.Marshal(s)
	var out Session
	_ = json.Unmarshal(b, &out)
	if out.Messages == nil {
		out.Messages = []Message{}
	}
	return out
}

func (e *Env) subscribe() chan StreamEvent {
	e.init()
	ch := make(chan StreamEvent, 256)
	e.mu.Lock()
	e.subs[ch] = struct{}{}
	e.mu.Unlock()
	return ch
}

func (e *Env) unsubscribe(ch chan StreamEvent) {
	e.init()
	e.mu.Lock()
	delete(e.subs, ch)
	e.mu.Unlock()
}

func (e *Env) broadcast(ev StreamEvent) {
	e.init()
	e.mu.Lock()
	defer e.mu.Unlock()
	e.broadcastLocked(ev)
}

// Nonblocking fanout under the admission lock keeps terminal status ordered
// before a new run's events.
func (e *Env) broadcastLocked(ev StreamEvent) {
	if s := e.sessions[ev.SessionID]; s != nil {
		ev.SessionTitle = s.Title
		for s.ParentID != "" {
			ev.RootSessionID = s.ParentID
			s = e.sessions[s.ParentID]
			if s == nil {
				break
			}
		}
	}
	key := ev.SessionID + ":" + ev.ToolCallID
	switch ev.Type {
	case "tool.running":
		e.activities[key] = ev
	case "tool.progress":
		if active, ok := e.activities[key]; ok {
			active.Output += ev.Delta
			if len(active.Output) > 32768 {
				active.Output = active.Output[len(active.Output)-32768:]
			}
			e.activities[key] = active
		}
	case "tool.done":
		delete(e.activities, key)
	case "session.status":
		if ev.Status != "running" {
			for k, a := range e.activities {
				if a.SessionID == ev.SessionID {
					delete(e.activities, k)
				}
			}
		}
	}
	for ch := range e.subs {
		select {
		case ch <- ev:
		default:
			// A dropped event can be a terminal status, permission, or message,
			// not just a delta. Discard the stale backlog and require a fresh
			// snapshot for every session (the queue is shared across sessions).
		drain:
			for {
				select {
				case <-ch:
				default:
					break drain
				}
			}
			ch <- StreamEvent{Type: "sync.required"}
			ch <- ev
		}
	}
}

func (e *Env) activitiesFor(id string) []StreamEvent {
	e.init()
	e.mu.Lock()
	defer e.mu.Unlock()
	out := []StreamEvent{}
	for _, ev := range e.activities {
		if ev.SessionID == id || ev.RootSessionID == id {
			out = append(out, ev)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SessionID+out[i].ToolCallID < out[j].SessionID+out[j].ToolCallID })
	return out
}

func (e *Env) resolveWorkspace(rootID, workdir string) (Root, string, string, error) {
	if len(e.Roots) == 0 {
		return Root{}, "", "", errors.New("agent has no configured roots")
	}
	var chosen *Root
	if rootID == "" {
		chosen = &e.Roots[0]
	} else {
		for i := range e.Roots {
			if e.Roots[i].ID == rootID {
				chosen = &e.Roots[i]
				break
			}
		}
	}
	if chosen == nil {
		return Root{}, "", "", fmt.Errorf("unknown root %q", rootID)
	}
	if workdir == "" {
		workdir = "/"
	}
	if !strings.HasPrefix(workdir, "/") {
		workdir = "/" + workdir
	}
	abs, err := paths.Resolve(chosen.Path, workdir)
	if err != nil {
		return Root{}, "", "", err
	}
	cleanWork := "/"
	if rel, rErr := filepath.Rel(chosen.Path, abs); rErr == nil && rel != "." {
		cleanWork = "/" + filepath.ToSlash(rel)
	}
	return *chosen, cleanWork, abs, nil
}

func sessionPreview(s *Session) string {
	// The last thing said: the assistant's final text, else the user's last prompt.
	for i := len(s.Messages) - 1; i >= 0; i-- {
		m := s.Messages[i]
		if m.Role != "assistant" && m.Role != "user" {
			continue
		}
		for j := len(m.Parts) - 1; j >= 0; j-- {
			p := m.Parts[j]
			if p.Type == "text" && strings.TrimSpace(p.Text) != "" && !strings.HasPrefix(p.Text, "<system-reminder>") {
				t := strings.Join(strings.Fields(p.Text), " ")
				r := []rune(t)
				if len(r) > 80 {
					t = string(r[:80]) + "…"
				}
				return t
			}
		}
	}
	return ""
}

func (e *Env) ListSessions(includeChildren bool) []SessionSummary {
	e.init()
	e.mu.Lock()
	defer e.mu.Unlock()

	out := make([]SessionSummary, 0, len(e.sessions))
	for _, s := range e.sessions {
		if !includeChildren && s.ParentID != "" {
			continue
		}
		_, isRun := e.running[s.ID]
		sum := sessionSummary(s)
		if r := e.records[s.ID]; r != nil {
			sum = r.index.Summary
		}
		sum.Running = isRun
		sum.PendingPermission = e.perms.PendingForSession(s.ID)
		if err := e.sessionErrors[s.ID]; err != nil {
			sum.StorageError = err.Error()
		}
		out = append(out, sum)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Pinned != out[j].Pinned {
			return out[i].Pinned
		}
		return out[i].UpdatedAt > out[j].UpdatedAt
	})
	return out
}

// UpdateSessionMeta renames and/or pins a session (nil leaves a field alone).
func (e *Env) UpdateSessionMeta(id string, title *string, pinned *bool) (SessionSummary, error) {
	e.init()
	e.mu.Lock()
	s := e.sessionLocked(id)
	if s == nil {
		e.mu.Unlock()
		return SessionSummary{}, e.sessionStorageError(id)
	}
	if e.maintenance[id] != nil {
		e.mu.Unlock()
		return SessionSummary{}, errors.New("会话正在维护")
	}
	beforeTitle, beforePinned := s.Title, s.Pinned
	if title != nil {
		t := strings.TrimSpace(*title)
		if t == "" {
			e.mu.Unlock()
			return SessionSummary{}, errors.New("title must not be empty")
		}
		if r := []rune(t); len(r) > 120 {
			t = string(r[:120])
		}
		s.Title = t
	}
	if pinned != nil {
		s.Pinned = *pinned
	}
	// Renaming or pinning is not activity: UpdatedAt stays, so the list does not reorder.
	if err := e.persistSessionLocked(s); err != nil {
		s.Title, s.Pinned = beforeTitle, beforePinned
		e.mu.Unlock()
		return SessionSummary{}, err
	}
	sum := SessionSummary{ID: s.ID, Title: s.Title, Pinned: s.Pinned, Root: s.Root, Workdir: s.Workdir, Agent: s.Agent, Model: s.Model, MessageCount: len(s.Messages), CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt}
	e.mu.Unlock()
	e.broadcast(StreamEvent{Type: "session.title", SessionID: id, Title: sum.Title})
	return sum, nil
}

// UpdateSessionPermission updates a session's permission mode and/or rules in
// place and immediately resolves pending prompts that are now allowed or denied.
func (e *Env) UpdateSessionPermission(id string, permMode *string, rules *[]PermissionRule) ([]string, error) {
	e.init()
	var mode string
	if permMode != nil {
		mode = strings.ToLower(strings.TrimSpace(*permMode))
		if mode != "ask" && mode != "auto" && mode != "full_access" {
			return nil, errors.New("permission_mode must be ask, auto, or full_access")
		}
	}
	e.mu.Lock()
	s := e.sessionLocked(id)
	if s == nil {
		e.mu.Unlock()
		return nil, e.sessionStorageError(id)
	}
	beforeMode := s.PermissionMode
	beforeRules := s.PermissionRules
	if permMode != nil {
		s.PermissionMode = mode
	}
	if rules != nil {
		s.PermissionRules = append([]PermissionRule(nil), (*rules)...)
	}
	if err := e.persistSessionLocked(s); err != nil {
		s.PermissionMode = beforeMode
		s.PermissionRules = beforeRules
		e.mu.Unlock()
		return nil, err
	}
	agentMode := s.Agent
	isSubagent := s.ParentID != ""
	effMode := s.PermissionMode
	effRules := append([]PermissionRule(nil), s.PermissionRules...)
	e.mu.Unlock()
	resolved := e.perms.ResolveSessionPending(id, agentMode, isSubagent, effMode, effRules)
	return resolved, nil
}

// SearchHit is one session found by SearchSessions.
type SearchHit struct {
	SessionID string `json:"session_id"`
	Title     string `json:"title"`
	Workdir   string `json:"workdir"`
	UpdatedAt int64  `json:"updated_at"`
	MessageID string `json:"message_id,omitempty"`
	Snippet   string `json:"snippet,omitempty"`
}

// SearchSessions finds sessions whose title or conversation text contains every
// word of query (case-insensitive). One hit per session, newest first.
func (e *Env) SearchSessions(query string, limit int) []SearchHit {
	hits, _ := e.searchSessionsContext(context.Background(), query, limit)
	return hits
}
func (e *Env) searchSessionsContext(ctx context.Context, query string, limit int) ([]SearchHit, error) {
	e.init()
	words := strings.Fields(strings.ToLower(query))
	if len(words) == 0 {
		return nil, nil
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var hits []SearchHit
	summaries := e.ListSessions(false)
	sort.Slice(summaries, func(i, j int) bool { return summaries[i].UpdatedAt > summaries[j].UpdatedAt })
	for _, sum := range summaries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		s, err := e.searchSession(ctx, sum.ID)
		if err != nil {
			return nil, err
		}
		var allText strings.Builder
		allText.WriteString(strings.ToLower(s.Title))
		var texts []struct{ id, text string }
		for _, m := range s.Messages {
			for _, p := range m.Parts {
				if (p.Type == "text" || p.Type == "compaction") && p.Text != "" && !strings.HasPrefix(p.Text, "<system-reminder>") {
					allText.WriteByte('\n')
					allText.WriteString(strings.ToLower(p.Text))
					texts = append(texts, struct{ id, text string }{m.ID, p.Text})
				}
			}
		}
		all := allText.String()
		matched := true
		for _, w := range words {
			if !strings.Contains(all, w) {
				matched = false
				break
			}
		}
		if !matched {
			continue
		}
		hit := SearchHit{SessionID: s.ID, Title: s.Title, Workdir: s.Workdir, UpdatedAt: s.UpdatedAt}
		for _, t := range texts {
			low := strings.ToLower(t.text)
			if idx := strings.Index(low, words[0]); idx >= 0 {
				rs := []rune(t.text)
				// idx is a byte offset into the lowered copy; recompute on runes to stay valid.
				start := len([]rune(low[:idx])) - 24
				if start < 0 {
					start = 0
				}
				end := start + 90
				if end > len(rs) {
					end = len(rs)
				}
				if start > end {
					start = end
				}
				hit.MessageID = t.id
				hit.Snippet = strings.Join(strings.Fields(string(rs[start:end])), " ")
				break
			}
		}
		hits = append(hits, hit)
		if len(hits) >= limit {
			break
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].UpdatedAt > hits[j].UpdatedAt })
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits, nil
}

// ExportMarkdown renders a session as one readable Markdown document.
func (e *Env) ExportMarkdown(id string) (string, string, error) {
	sess, _, _, err := e.GetSession(id)
	if err != nil {
		return "", "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", sess.Title)
	fmt.Fprintf(&b, "- Workdir: `%s:%s`\n- Model: `%s`\n- Created: %s\n\n", sess.Root, sess.Workdir, sess.Model, time.UnixMilli(sess.CreatedAt).Format("2006-01-02 15:04"))
	for _, m := range sess.Messages {
		switch m.Role {
		case "user":
			for _, p := range m.Parts {
				if p.Type == "text" && !strings.HasPrefix(p.Text, "<system-reminder>") {
					b.WriteString("## 👤 User\n\n" + strings.TrimSpace(p.Text) + "\n\n")
				}
			}
		case "assistant":
			b.WriteString("## 🤖 Assistant\n\n")
			results := map[string]Part{}
			for _, p := range m.Parts {
				if p.Type == "tool-result" {
					results[p.ToolCallID] = p
				}
			}
			for _, p := range m.Parts {
				switch p.Type {
				case "text":
					b.WriteString(strings.TrimSpace(p.Text) + "\n\n")
				case "tool-call":
					fmt.Fprintf(&b, "<details><summary>🛠 %s</summary>\n\n```json\n%s\n```\n", p.ToolName, strings.TrimSpace(string(p.Input)))
					if r, ok := results[p.ToolCallID]; ok {
						out := r.Output
						if len(out) > 4000 {
							out = out[:4000] + "\n…[truncated]"
						}
						b.WriteString("\n```\n" + out + "\n```\n")
					}
					b.WriteString("\n</details>\n\n")
				}
			}
			if m.Error != "" {
				b.WriteString("> ⚠️ " + m.Error + "\n\n")
			}
		case "compaction":
			if len(m.Parts) > 0 {
				b.WriteString("## 📦 Checkpoint\n\n" + strings.TrimSpace(m.Parts[0].Text) + "\n\n")
			}
		}
	}
	name := strings.Map(func(r rune) rune {
		if strings.ContainsRune(`\/:*?"<>|`, r) || r < 32 {
			return '_'
		}
		return r
	}, sess.Title)
	return name + ".md", b.String(), nil
}

func (e *Env) GetSession(id string) (Session, bool, *PermissionQuestion, error) {
	e.init()
	e.mu.Lock()
	defer e.mu.Unlock()
	s := e.sessionLocked(id)
	if s == nil {
		return Session{}, false, nil, e.sessionStorageError(id)
	}
	_, isRun := e.running[id]
	if run := e.running[id]; run != nil {
		s.Budget = run.meter.snapshot()
	}
	var out Session
	_ = e.sessionIOLocked(id, func() error { out = cloneSession(s); return nil })
	for i := range out.Inbox {
		out.Inbox[i].Held = !e.inboxActiveLocked(id, out.Inbox[i].ID)
	}
	return out, isRun, e.perms.PendingForSession(id), nil
}

func (e *Env) inboxActiveLocked(sessionID, itemID string) bool {
	run := e.running[sessionID]
	if run == nil {
		return false
	}
	for _, items := range [][]InboxItem{run.inbox, run.queued} {
		for _, item := range items {
			if item.ID == itemID {
				return true
			}
		}
	}
	return false
}

func (e *Env) inboxSnapshotLocked(s *Session) []InboxItem {
	items := append([]InboxItem(nil), s.Inbox...)
	for i := range items {
		items[i].Held = !e.inboxActiveLocked(s.ID, items[i].ID)
		items[i].Provider = ProviderConfig{}
	}
	return items
}

func (e *Env) DeleteSession(id string) error {
	e.init()
	e.StopSession(id)

	e.mu.Lock()
	defer e.mu.Unlock()
	e.waitSessionLocked(id)
	if e.maintenance[id] != nil || e.maintenance["snapshots:gc"] != nil {
		return errors.New("session maintenance is still stopping; retry after it finishes")
	}
	if _, ok := e.sessions[id]; !ok {
		return nil
	}
	// Reserve the complete descendant set before releasing the admission lock.
	toDelete := []string{id}
	selected := map[string]bool{id: true}
	for i := 0; i < len(toDelete); i++ {
		for cid, cs := range e.sessions {
			if cs.ParentID == toDelete[i] && !selected[cid] {
				selected[cid] = true
				toDelete = append(toDelete, cid)
			}
		}
	}
	for _, did := range toDelete {
		if e.running[did] != nil || e.maintenance[did] != nil || e.sessionIO[did] != nil {
			return errors.New("会话正在停止或落盘，请等待完成后删除")
		}
	}
	for _, did := range toDelete {
		e.maintenance[did] = func() {}
	}
	defer func() {
		for _, did := range toDelete {
			delete(e.maintenance, did)
		}
	}()
	attachmentCandidates := map[string]bool{}
	for _, did := range toDelete {
		if r := e.records[did]; r != nil {
			for _, ref := range r.index.Attachments {
				attachmentCandidates[ref] = true
			}
		}
		if s := e.sessions[did]; s != nil {
			a, _ := sessionReferences(s)
			for _, ref := range a {
				attachmentCandidates[ref] = true
			}
		}
	}
	if err := e.deleteSessionsDiskLocked(id, toDelete); err != nil {
		return err
	}
	for _, did := range toDelete {
		delete(e.sessions, did)
		delete(e.records, did)
		delete(e.sessionErrors, did)
	}
	e.removeUnusedAttachmentsLocked(attachmentCandidates)
	return nil
}

func (e *Env) StopSession(id string) bool {
	e.init()
	e.perms.CancelSession(id)
	e.mu.Lock()
	e.waitSessionLocked(id)
	ar, ok := e.running[id]
	maintenance := e.maintenance[id]
	if ok {
		ar.stopRequested = true
	}
	e.mu.Unlock()
	if ok && ar.cancel != nil {
		ar.cancel()
		return true
	}
	if maintenance != nil {
		maintenance()
		return true
	}
	return false
}

func (e *Env) StopAll() {
	e.proposalMu.Lock()
	for _, cancel := range e.proposalCancels {
		cancel()
	}
	e.proposalMu.Unlock()
	e.init()
	e.mu.Lock()
	ids := make([]string, 0, len(e.running))
	for id := range e.running {
		ids = append(ids, id)
	}
	for id := range e.maintenance {
		ids = append(ids, id)
	}
	e.mu.Unlock()
	for _, id := range ids {
		e.StopSession(id)
	}
}

func (e *Env) updateTodos(sessionID string, todos []TodoItem) {
	e.mu.Lock()
	s := e.sessionLocked(sessionID)
	ok := s != nil
	if ok {
		s.Todos = append([]TodoItem(nil), todos...)
		s.UpdatedAt = time.Now().UnixMilli()
		_ = e.persistSessionLocked(s)
	}
	e.mu.Unlock()
	if ok {
		e.broadcast(StreamEvent{
			Type:      "todos.updated",
			SessionID: sessionID,
			Todos:     todos,
		})
	}
}

func formatUserContent(text string, attachments []ContextAttachment) string {
	var blocks []string
	for _, att := range attachments {
		if strings.TrimSpace(att.Content) == "" {
			continue
		}
		header := fmt.Sprintf("<context kind=%q label=%q", att.Kind, att.Label)
		if att.Path != "" {
			header += fmt.Sprintf(" path=%q", att.Path)
		}
		header += ">"
		blocks = append(blocks, header+"\n"+strings.TrimRight(att.Content, "\n")+"\n</context>")
	}
	if strings.TrimSpace(text) != "" {
		blocks = append(blocks, strings.TrimSpace(text))
	}
	return strings.Join(blocks, "\n\n")
}

// RunInput is the payload for ai.run.
type RunInput struct {
	SessionID               string              `json:"session_id,omitempty"`
	InboxID                 string              `json:"inbox_id,omitempty"`
	Root                    string              `json:"root,omitempty"`
	Workdir                 string              `json:"workdir,omitempty"`
	Agent                   string              `json:"agent,omitempty"`           // "build" | "plan" | "orchestrator"
	PermissionMode          string              `json:"permission_mode,omitempty"` // "ask" | "auto" | "full_access"
	PermissionRules         []PermissionRule    `json:"permission_rules,omitempty"`
	Text                    string              `json:"text"`
	Attachments             []ContextAttachment `json:"attachments,omitempty"`
	Delivery                string              `json:"delivery,omitempty"` // "steer" | "queue"
	Provider                ProviderConfig      `json:"provider"`
	SubagentProvider        *ProviderConfig     `json:"subagent_provider,omitempty"`
	SubagentPermissionMode  string              `json:"subagent_permission_mode,omitempty"`
	SubagentPermissionRules []PermissionRule    `json:"subagent_permission_rules,omitempty"`
	Options                 *RunOptions         `json:"options,omitempty"`
}

// StartRun creates or resumes a session, enqueues the user prompt (supporting live steering
// if already running, just like OpenCode's inbox), and spawns the background runner goroutine.
func (e *Env) StartRun(in RunInput) (SessionSummary, error) {
	e.init()
	if e.recoveryErr != nil {
		return SessionSummary{}, e.recoveryErr
	}
	if in.Options != nil {
		data, err := json.Marshal(in.Options)
		if err != nil {
			return SessionSummary{}, err
		}
		var options RunOptions
		if err = json.Unmarshal(data, &options); err != nil {
			return SessionSummary{}, err
		}
		in.Options = &options
	}
	var prepErr error
	in.Provider, prepErr = prepareSubscription(in.Provider)
	if prepErr != nil {
		return SessionSummary{}, prepErr
	}
	in.Provider, prepErr = prepareModelOptions(in.Provider)
	if prepErr != nil {
		return SessionSummary{}, prepErr
	}
	if in.SubagentProvider != nil {
		subProv := *in.SubagentProvider
		subProv, prepErr = prepareSubscription(subProv)
		if prepErr != nil {
			return SessionSummary{}, prepErr
		}
		subProv, prepErr = prepareModelOptions(subProv)
		if prepErr != nil {
			return SessionSummary{}, prepErr
		}
		in.SubagentProvider = &subProv
	}
	if strings.TrimSpace(in.Text) == "" && len(in.Attachments) == 0 && in.InboxID == "" {
		return SessionSummary{}, errors.New("prompt text must not be empty")
	}
	if strings.TrimSpace(in.Provider.Model) == "" {
		return SessionSummary{}, errors.New("model must not be empty")
	}

	agentMode := strings.ToLower(strings.TrimSpace(in.Agent))
	if agentMode != "plan" && agentMode != "build" && agentMode != "orchestrator" {
		agentMode = "build"
	}
	permMode := strings.ToLower(strings.TrimSpace(in.PermissionMode))
	if permMode != "auto" && permMode != "ask" && permMode != "full_access" {
		permMode = "ask"
	}
	subPermMode := strings.ToLower(strings.TrimSpace(in.SubagentPermissionMode))
	if subPermMode != "auto" && subPermMode != "ask" && subPermMode != "full_access" {
		subPermMode = ""
	}

	e.mu.Lock()
	e.waitSessionLocked(in.SessionID)
	if in.SessionID != "" && e.sessionLocked(in.SessionID) == nil {
		err := e.sessionStorageError(in.SessionID)
		e.mu.Unlock()
		return SessionSummary{}, err
	}
	if e.maintenance[in.SessionID] != nil || e.maintenance["snapshots:gc"] != nil {
		e.mu.Unlock()
		return SessionSummary{}, errors.New("会话正在压缩或回退，请等待完成后再发送")
	}
	if in.InboxID != "" {
		s := e.sessions[in.SessionID]
		if s == nil || e.running[in.SessionID] != nil {
			e.mu.Unlock()
			return SessionSummary{}, errors.New("请等待任务停止后再发送保留的输入")
		}
		found := false
		for _, item := range s.Inbox {
			if item.ID == in.InboxID {
				in.Text, in.Attachments = item.Text, item.Attachments
				if in.Options == nil {
					in.Options = item.Options
				}
				found = true
				break
			}
		}
		if !found {
			e.mu.Unlock()
			return SessionSummary{}, errors.New("待发送输入不存在或已经处理")
		}
	}
	// Deletion uses the same lock: a shared reference must not disappear
	// between validation and publishing this message/inbox entry.
	if err := e.validateAttachments(in.Attachments, in.Provider); err != nil {
		e.mu.Unlock()
		return SessionSummary{}, err
	}
	var s *Session
	if in.SessionID != "" {
		s = e.sessions[in.SessionID]
		if s == nil {
			e.mu.Unlock()
			return SessionSummary{}, fmt.Errorf("session not found: %s", in.SessionID)
		}
		if in.Workdir != "" && len(s.Messages) == 0 {
			if rt, cw, _, err := e.resolveWorkspace(in.Root, in.Workdir); err == nil {
				s.Root = rt.ID
				s.Workdir = cw
			}
		}
	} else {
		rt, cw, _, err := e.resolveWorkspace(in.Root, in.Workdir)
		if err != nil {
			e.mu.Unlock()
			return SessionSummary{}, err
		}
		now := time.Now().UnixMilli()
		initialTitle := in.Text
		if strings.TrimSpace(initialTitle) == "" && len(in.Attachments) > 0 {
			label := in.Attachments[0].Label
			if label == "" && in.Attachments[0].AttachmentID != "" {
				if m, err := e.attachmentMeta(in.Attachments[0].AttachmentID); err == nil {
					label = m.Name
				}
			}
			initialTitle = "附件：" + label
		}
		s = &Session{
			ID:             NewID("ses"),
			Title:          fallbackTitle(initialTitle),
			Root:           rt.ID,
			Workdir:        cw,
			Agent:          agentMode,
			PermissionMode: permMode,
			Model:          in.Provider.Model,
			Protocol:       in.Provider.Protocol,
			Messages:       []Message{},
			CreatedAt:      now,
			UpdatedAt:      now,
		}
		e.sessions[s.ID] = s
	}

	// Resuming a child preserves its read-only role and delegation boundary.
	depth := 0
	if s.ParentID != "" {
		depth = 1
		if e.running[s.ParentID] != nil {
			e.mu.Unlock()
			return SessionSummary{}, errors.New("子代理由主任务调度中；请在主对话补充指令，主任务结束后可继续子会话")
		}
		if s.Agent == "explore" {
			agentMode = "explore"
		}
	}
	if in.Delivery != "" && in.Delivery != "steer" && in.Delivery != "queue" {
		if in.SessionID == "" {
			delete(e.sessions, s.ID)
		}
		e.mu.Unlock()
		return SessionSummary{}, errors.New("未知发送方式")
	}
	var budgetConfig ExtensionConfig
	budgetSource := "default"
	if ar := e.running[s.ID]; ar != nil && in.Delivery != "queue" {
		if in.Options.changed() {
			e.mu.Unlock()
			return SessionSummary{}, errors.New("补充指令沿用当前任务设置；请改为排队发送以使用独立预算")
		}
		budgetConfig, budgetSource = ar.meter.config, ar.meter.source
	} else {
		_, _, budgetWork, budgetErr := e.resolveWorkspace(s.Root, s.Workdir)
		var tag string
		if budgetErr == nil {
			budgetConfig, tag, budgetErr = loadExtensionConfig(budgetWork)
		}
		if budgetErr == nil {
			budgetConfig, budgetErr = applyRunOptions(budgetConfig, in.Options)
		}
		if budgetErr != nil {
			if in.SessionID == "" {
				delete(e.sessions, s.ID)
			}
			e.mu.Unlock()
			return SessionSummary{}, budgetErr
		}
		if tag != "" {
			budgetSource = "project"
		}
		if in.Options.changed() {
			budgetSource = "message"
		}
	}

	// If already running, push into activeRun.inbox for OpenCode-style live steering!
	if ar, busy := e.running[s.ID]; busy {
		item := InboxItem{
			ID:                      NewID("inb"),
			Text:                    in.Text,
			Agent:                   agentMode,
			Delivery:                in.Delivery,
			Attachments:             in.Attachments,
			CreatedAt:               time.Now().UnixMilli(),
			PermissionMode:          permMode,
			PermissionRules:         append([]PermissionRule(nil), in.PermissionRules...),
			Provider:                in.Provider,
			SubagentProvider:        in.SubagentProvider,
			SubagentPermissionMode:  subPermMode,
			SubagentPermissionRules: append([]PermissionRule(nil), in.SubagentPermissionRules...),
			Runtime:                 runtimeInfo(in.Provider),
			Options:                 in.Options,
			AdmittedConfig:          &budgetConfig,
			ConfigSource:            budgetSource,
		}
		if item.Delivery != "queue" {
			item.Delivery = "steer"
		}
		s.Inbox = append(s.Inbox, item)
		if err := e.persistSessionLocked(s); err != nil {
			s.Inbox = s.Inbox[:len(s.Inbox)-1]
			e.mu.Unlock()
			return SessionSummary{}, err
		}
		if item.Delivery == "queue" {
			ar.queued = append(ar.queued, item)
		} else {
			// "steer" is the interactive path: it is inserted before the next
			// model step. Queue messages are held until the current turn finishes.
			ar.inbox = append(ar.inbox, item)
		}
		sum := SessionSummary{
			ID:           s.ID,
			Title:        s.Title,
			Root:         s.Root,
			Workdir:      s.Workdir,
			Agent:        s.Agent,
			Model:        s.Model,
			Running:      true,
			MessageCount: len(s.Messages),
			UpdatedAt:    s.UpdatedAt,
		}
		pending := e.inboxSnapshotLocked(s)
		e.mu.Unlock()
		e.broadcast(StreamEvent{Type: "inbox.updated", SessionID: s.ID, Inbox: pending})
		return sum, nil
	}

	meter := newRunMeter(budgetConfig)
	meter.source = budgetSource
	before := *s
	before.Messages = append([]Message(nil), s.Messages...)
	before.Inbox = append([]InboxItem(nil), s.Inbox...)
	prevAgent := s.Agent
	recoverInterruptedTools(s)
	s.Agent = agentMode
	s.PermissionMode = permMode
	s.PermissionRules = append([]PermissionRule(nil), in.PermissionRules...)
	s.Model = in.Provider.Model
	s.Protocol = in.Provider.Protocol
	s.UpdatedAt = time.Now().UnixMilli()
	s.Budget = meter.snapshot()
	if in.InboxID != "" {
		for i, item := range s.Inbox {
			if item.ID == in.InboxID {
				s.Inbox = append(s.Inbox[:i], s.Inbox[i+1:]...)
				break
			}
		}
	}

	// Inject Plan mode enter/leave reminder when switching agents (matching OpenCode's PlanPlugin)
	planDir := filepath.Join(e.StateDir, "ai", "plans")
	if agentMode == "plan" && (len(s.Messages) == 0 || prevAgent != "plan") {
		s.Messages = append(s.Messages, Message{
			ID:        NewID("msg"),
			SessionID: s.ID,
			Role:      "user",
			Parts:     []Part{{Type: "text", ID: NewID("prt"), Text: PlanEnterReminder(planDir)}},
			CreatedAt: time.Now().UnixMilli(),
		})
	} else if agentMode != "plan" && prevAgent == "plan" && len(s.Messages) > 0 {
		s.Messages = append(s.Messages, Message{
			ID:        NewID("msg"),
			SessionID: s.ID,
			Role:      "user",
			Parts:     []Part{{Type: "text", ID: NewID("prt"), Text: PlanLeaveReminder}},
			CreatedAt: time.Now().UnixMilli(),
		})
	}

	isFirstPrompt := countRealUserMessages(s.Messages) == 0
	userMsg := Message{
		ID:        NewID("msg"),
		SessionID: s.ID,
		Role:      "user",
		Agent:     agentMode,
		Parts:     e.userParts(in.Text, in.Attachments),
		CreatedAt: time.Now().UnixMilli(),
		Budget:    meter.snapshot(),
	}
	s.Messages = append(s.Messages, userMsg)
	if err := e.persistSessionLocked(s); err != nil {
		*s = before
		if in.SessionID == "" {
			delete(e.sessions, s.ID)
		}
		e.mu.Unlock()
		return SessionSummary{}, err
	}

	runCtx, cancel := context.WithCancel(context.Background())
	turnCtx, turnCancel := meter.context(runCtx)
	ar := &activeRun{
		cancel:            cancel,
		turnCtx:           turnCtx,
		turnCancel:        turnCancel,
		provider:          in.Provider,
		subagentProvider:  in.SubagentProvider,
		subagentPermMode:  subPermMode,
		subagentPermRules: append([]PermissionRule(nil), in.SubagentPermissionRules...),
		meter:             meter,
	}
	e.running[s.ID] = ar

	sum := SessionSummary{
		ID:           s.ID,
		Title:        s.Title,
		Root:         s.Root,
		Workdir:      s.Workdir,
		Agent:        s.Agent,
		Model:        s.Model,
		Running:      true,
		MessageCount: len(s.Messages),
		UpdatedAt:    s.UpdatedAt,
	}
	sid := s.ID
	meter.onChange = func() { e.publishRunBudget(sid, meter) }
	firstPromptText := in.Text
	provCopy := in.Provider
	e.mu.Unlock()

	msgCopy := userMsg
	e.broadcast(StreamEvent{
		Type:      "message.added",
		SessionID: sid,
		MessageID: userMsg.ID,
		Message:   &msgCopy,
	})
	e.broadcast(StreamEvent{
		Type:      "session.status",
		SessionID: sid,
		Status:    "running",
		Budget:    meter.snapshot(),
	})

	if isFirstPrompt && strings.TrimSpace(firstPromptText) != "" && enabledByDefault(budgetConfig.AutoTitle) {
		go e.generateTitleAsync(turnCtx, sid, firstPromptText, provCopy, meter)
	}

	go e.runLoop(runCtx, sid, depth)
	return sum, nil
}

func countRealUserMessages(msgs []Message) int {
	n := 0
	for _, m := range msgs {
		if m.Role == "user" && len(m.Parts) > 0 && !strings.HasPrefix(m.Parts[0].Text, "<system-reminder>") {
			n++
		}
	}
	return n
}

func fallbackTitle(text string) string {
	t := strings.TrimSpace(strings.ReplaceAll(text, "\n", " "))
	runes := []rune(t)
	if len(runes) == 0 {
		return "New session"
	}
	if len(runes) > 42 {
		return string(runes[:42]) + "…"
	}
	return string(runes)
}

func (e *Env) generateTitleAsync(ctx context.Context, sessionID, promptText string, cfg ProviderConfig, meters ...*runMeter) {
	cctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()

	temp := 0.3
	var meter *runMeter
	if len(meters) > 0 {
		meter = meters[0]
	}
	resp, err := streamBudgeted(cctx, LLMRequest{
		SessionID:       sessionID,
		Initiator:       "agent",
		Provider:        cfg,
		System:          []string{PromptTitle},
		Messages:        []Message{{ID: NewID("msg"), Role: "user", Parts: []Part{{Type: "text", Text: promptText}}}},
		MaxTokens:       80,
		BudgetAuxiliary: true,
		Temperature:     &temp,
	}, e.proxyFor(cfg), nil, meter)
	if err != nil {
		return
	}
	var sb strings.Builder
	for _, p := range resp.Parts {
		if p.Type == "text" {
			sb.WriteString(p.Text)
		}
	}
	title := strings.TrimSpace(sb.String())
	if idx := strings.IndexByte(title, '\n'); idx >= 0 {
		title = strings.TrimSpace(title[:idx])
	}
	title = strings.Trim(title, `"'“”。.`)
	if title == "" {
		return
	}
	runes := []rune(title)
	if len(runes) > 60 {
		title = string(runes[:60])
	}

	e.mu.Lock()
	s := e.sessionLocked(sessionID)
	if s != nil && ctx.Err() == nil && (meter == nil || s.Budget != nil && s.Budget.ID == meter.id) {
		s.Title = title
		s.UpdatedAt = time.Now().UnixMilli()
		_ = e.persistSessionLocked(s)
	} else {
		s = nil
	}
	e.mu.Unlock()
	if s != nil {
		e.broadcast(StreamEvent{
			Type:      "session.title",
			SessionID: sessionID,
			Title:     title,
		})
	}
}

func (e *Env) finishRunLocked(sessionID string, owned *activeRun) {
	e.waitSessionLocked(sessionID)
	if owned == nil || e.running[sessionID] != owned {
		return
	}
	e.perms.CancelSession(sessionID)
	owned.cancel()
	if owned.turnCancel != nil {
		owned.turnCancel()
	}
	delete(e.running, sessionID)
	if s := e.sessionLocked(sessionID); s != nil {
		recoverInterruptedTools(s)
		s.Budget = owned.meter.snapshot()
		_ = e.persistSessionLocked(s)
	}
	e.broadcastLocked(StreamEvent{Type: "session.status", SessionID: sessionID, Status: "idle", Budget: owned.meter.snapshot()})
}

func (e *Env) publishRunBudget(sessionID string, meter *runMeter) {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := e.sessionLocked(sessionID)
	if s == nil || s.Budget == nil || s.Budget.ID != meter.id {
		return // a late title receipt cannot replace a newer run's counters
	}
	state := meter.snapshot()
	s.Budget = state
	if e.running[sessionID] == nil {
		_ = e.persistSessionLocked(s)
	}
	e.broadcastLocked(StreamEvent{Type: "run.budget", SessionID: sessionID, Budget: state})
}

func (e *Env) runLoop(baseCtx context.Context, sessionID string, depth int) {
	e.mu.Lock()
	owned := e.running[sessionID]
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		e.finishRunLocked(sessionID, owned)
		e.mu.Unlock()
	}()

	if owned == nil {
		return
	}
	ctx := owned.turnCtx
	if ctx == nil {
		ctx = baseCtx
	}
	var lastCalls []toolSignature
	idleBoundary := false
	var extensions *extensionRuntime
	defer func() {
		if extensions != nil {
			extensions.close()
		}
	}()

	for step := 0; ; step++ {
		if ctx.Err() != nil {
			if owned != nil {
				if err := owned.meter.timeError(); err != nil {
					e.recordRunError(sessionID, "", "", err, LLMResponse{})
				}
			}
			return
		}

		e.mu.Lock()
		s := e.sessionLocked(sessionID)
		ar := e.running[sessionID]
		if s == nil || ar == nil {
			e.mu.Unlock()
			return
		}
		// Move queued follow-ups only after the previous model/tool turn has
		// completed. This keeps the two composer delivery modes meaningful.
		if idleBoundary && len(ar.inbox) == 0 && len(ar.queued) > 0 {
			item := ar.queued[0]
			if item.AdmittedConfig == nil {
				e.mu.Unlock()
				e.recordError(sessionID, "", "排队输入缺少有效设置，请在待发送中重新发送。")
				return
			}
			if ar.turnCancel != nil {
				ar.turnCancel()
			}
			meter := newRunMeter(*item.AdmittedConfig)
			meter.source = item.ConfigSource
			meter.onChange = func() { e.publishRunBudget(sessionID, meter) }
			ar.meter = meter
			ar.turnCtx, ar.turnCancel = meter.context(baseCtx)
			ctx = ar.turnCtx
			s.Budget = meter.snapshot()
			step = 0
			ar.inbox = append(ar.inbox, ar.queued[0])
			ar.queued = ar.queued[1:]
			// Recreate extension connections with this message's admitted policy.
			if extensions != nil {
				e.mu.Unlock()
				extensions.close()
				extensions = nil
				e.mu.Lock()
			}
		}
		// Drain interactive steering messages submitted while running.
		var delivered []Message
		var pending []InboxItem
		if len(ar.inbox) > 0 {
			before := *s
			before.Messages = append([]Message(nil), s.Messages...)
			before.Inbox = append([]InboxItem(nil), s.Inbox...)
			lastCalls = nil
			for _, item := range ar.inbox {
				previousAgent := s.Agent
				if item.Agent != "" && (item.Agent == "build" || item.Agent == "plan" || item.Agent == "orchestrator") {
					s.Agent = item.Agent
				}
				if s.Agent != previousAgent {
					if s.Agent == "plan" {
						s.Messages = append(s.Messages, Message{ID: NewID("msg"), SessionID: s.ID, Role: "user",
							Parts: []Part{{Type: "text", ID: NewID("prt"), Text: PlanEnterReminder(filepath.Join(e.StateDir, "ai", "plans"))}}, CreatedAt: time.Now().UnixMilli()})
					} else if previousAgent == "plan" {
						s.Messages = append(s.Messages, Message{ID: NewID("msg"), SessionID: s.ID, Role: "user",
							Parts: []Part{{Type: "text", ID: NewID("prt"), Text: PlanLeaveReminder}}, CreatedAt: time.Now().UnixMilli()})
					}
				}
				ar.provider = item.Provider
				ar.subagentProvider = item.SubagentProvider
				ar.subagentPermMode = item.SubagentPermissionMode
				ar.subagentPermRules = append([]PermissionRule(nil), item.SubagentPermissionRules...)
				s.Model, s.Protocol = item.Provider.Model, item.Provider.Protocol
				s.PermissionMode = item.PermissionMode
				s.PermissionRules = append([]PermissionRule(nil), item.PermissionRules...)
				for i, pending := range s.Inbox {
					if pending.ID == item.ID {
						s.Inbox = append(s.Inbox[:i], s.Inbox[i+1:]...)
						break
					}
				}
				um := Message{
					ID:        NewID("msg"),
					SessionID: s.ID,
					Role:      "user",
					Agent:     s.Agent,
					Parts:     e.userParts(item.Text, item.Attachments),
					CreatedAt: item.CreatedAt,
					Budget:    ar.meter.snapshot(),
				}
				s.Messages = append(s.Messages, um)
				delivered = append(delivered, um)
			}
			ar.inbox = nil
			if err := e.persistSessionLocked(s); err != nil {
				*s = before
				e.mu.Unlock()
				e.recordError(sessionID, "", "无法保存待发送输入，任务已暂停；输入仍保留。")
				return
			}
			pending = e.inboxSnapshotLocked(s)
		}
		sessSnap := cloneSession(s)
		prov := ar.provider
		e.mu.Unlock()
		if len(delivered) > 0 {
			e.broadcast(StreamEvent{Type: "inbox.updated", SessionID: sessionID, Inbox: pending})
			for _, message := range delivered {
				e.broadcast(StreamEvent{Type: "message.added", SessionID: sessionID, MessageID: message.ID, Message: &message})
			}
		}

		rt, _, absWorkdir, err := e.resolveWorkspace(sessSnap.Root, sessSnap.Workdir)
		if err != nil {
			e.recordError(sessionID, prov.Model, err.Error())
			return
		}
		if extensions == nil {
			extensions, err = e.loadExtensions(ctx, rt.Path, absWorkdir, prov, owned.meter.config)
			if err != nil {
				if deadlineErr := owned.meter.timeError(); deadlineErr != nil {
					err = deadlineErr
				}
				e.recordRunError(sessionID, prov.Model, "", err, LLMResponse{})
				return
			}
		}

		// Auto-compaction check before issuing step request (matching OpenCode's runner)
		if depth == 0 && enabledByDefault(extensions.config.AutoCompact) && ShouldAutoCompact(&sessSnap, prov) {
			if _, cerr := e.compactInternal(ctx, sessionID, prov, absWorkdir, false); cerr == nil {
				e.mu.Lock()
				if cur := e.sessionLocked(sessionID); cur != nil {
					sessSnap = cloneSession(cur)
				}
				e.mu.Unlock()
			} else {
				var limit *budgetError
				if errors.As(cerr, &limit) {
					e.recordRunError(sessionID, prov.Model, "", cerr, LLMResponse{})
					return
				}
			}
		}

		tools := configuredToolDefinitions(sessSnap.Agent, depth, prov, extensions)
		tools = append(tools, extensions.definitions(sessSnap.Agent, prov)...)
		toolNames := make([]string, len(tools))
		for i, t := range tools {
			toolNames[i] = t.Name
		}
		sysPrompts := BuildSystemPrompts(sessSnap.Agent, prov, absWorkdir, toolNames, renderInstructions(extensions.instructions))
		activeMsgs := BuildActiveHistory(sessSnap.Messages)

		initiator := "user"
		if step > 0 || depth > 0 {
			initiator = "agent"
		}

		startTree := ""
		snapshotWarning := ""

		asstMsgID := NewID("msg")
		runtime := runtimeInfo(prov)
		contextState := activeContext(&sessSnap, prov, contextOverhead(sysPrompts, tools))
		e.mu.Lock()
		if cur := e.sessionLocked(sessionID); cur != nil {
			cur.Runtime = runtime
			cur.Context = contextState
		}
		e.mu.Unlock()
		e.broadcast(StreamEvent{
			Type:      "step.start",
			SessionID: sessionID,
			MessageID: asstMsgID,
			Runtime:   runtime,
			Context:   contextState,
			Budget:    owned.meter.snapshot(),
		})

		llmResp, llmErr := streamBudgeted(ctx, LLMRequest{
			SessionID:      sessionID,
			AffinityID:     sessSnap.ParentID,
			Initiator:      initiator,
			Provider:       prov,
			System:         sysPrompts,
			Messages:       activeMsgs,
			Tools:          tools,
			LoadAttachment: e.loadAttachment,
		}, e.proxyFor(prov), func(d LLMDelta) {
			switch d.Type {
			case "text":
				e.broadcast(StreamEvent{
					Type:      "text.delta",
					SessionID: sessionID,
					MessageID: asstMsgID,
					Delta:     d.Text,
				})
			case "reasoning":
				e.broadcast(StreamEvent{
					Type:      "reasoning.delta",
					SessionID: sessionID,
					MessageID: asstMsgID,
					Delta:     d.Text,
				})
			case "tool-call-start":
				e.broadcast(StreamEvent{
					Type:       "tool.start",
					SessionID:  sessionID,
					MessageID:  asstMsgID,
					ToolCallID: d.ToolCallID,
					ToolName:   d.ToolName,
				})
			}
		}, owned.meter)

		if llmErr != nil {
			if ctx.Err() != nil && owned.meter.timeError() == nil {
				if len(llmResp.Parts) > 0 {
					e.recordAbortedPartial(sessionID, asstMsgID, sessSnap.Agent, prov, sysPrompts, tools, llmResp)
				}
				return
			}
			// Context overflow recovery: run overflow compaction once and retry step!
			if depth == 0 && enabledByDefault(extensions.config.AutoCompact) && IsContextOverflowError(llmErr) {
				if _, cerr := e.compactInternal(ctx, sessionID, prov, absWorkdir, true); cerr == nil {
					continue
				}
			}
			e.recordRunError(sessionID, prov.Model, asstMsgID, llmErr, llmResp)
			return
		}

		// Collect tool calls from assistant parts
		var toolCalls []Part
		callIDs := map[string]bool{}
		for i, p := range llmResp.Parts {
			if p.Type == "tool-call" {
				if p.ToolCallID == "" || callIDs[p.ToolCallID] {
					p.ToolCallID = NewID("call")
					llmResp.Parts[i] = p
				}
				callIDs[p.ToolCallID] = true
				toolCalls = append(toolCalls, p)
			}
		}
		progressMessage := Message{ID: asstMsgID, SessionID: sessionID, Role: "assistant",
			Agent: sessSnap.Agent, Model: prov.Model, Runtime: runtime, Finish: "tool-running",
			Parts: append([]Part(nil), llmResp.Parts...), CreatedAt: time.Now().UnixMilli()}
		if depth == 0 && sessSnap.Agent == "build" && enabledByDefault(extensions.config.Snapshots) {
			for _, call := range toolCalls {
				if call.ToolName == "write" || call.ToolName == "edit" || call.ToolName == "apply_patch" ||
					call.ToolName == "shell" || call.ToolName == "subagent" || strings.HasPrefix(call.ToolName, "mcp_") {
					var captureErr error
					startTree, captureErr = e.snapshots.CaptureConfigured(ctx, absWorkdir, extensions.config.Snapshot)
					if captureErr != nil {
						snapshotWarning = captureErr.Error()
					}
					break
				}
			}
		}
		if startTree != "" {
			progressMessage.Snapshot = &StepSnapshot{Start: startTree}
		}
		if len(toolCalls) > 0 {
			if err := e.checkpointStep(progressMessage); err != nil {
				e.recordError(sessionID, prov.Model, "工具调用记录保存失败，未执行工具："+err.Error())
				return
			}
		}

		resultParts, toolErr := e.executeStepTools(ctx, toolContext{
			env: e, session: &sessSnap, provider: prov, rootPath: rt.Path,
			absWorkdir: absWorkdir, messageID: asstMsgID, depth: depth, extensions: extensions,
		}, toolCalls, progressMessage, &lastCalls)
		if toolErr != nil {
			e.recordError(sessionID, prov.Model, "工具结果保存失败，任务已暂停；请核对实际状态："+toolErr.Error())
			return
		}

		// Capture end-of-step shadow-git snapshot if tools ran
		var stepSnap *StepSnapshot
		if startTree != "" && len(toolCalls) > 0 {
			endTree, captureErr := e.snapshots.CaptureConfigured(context.Background(), absWorkdir, extensions.config.Snapshot)
			if captureErr != nil {
				snapshotWarning = captureErr.Error()
			}
			if endTree != "" && endTree != startTree {
				diffs, diffErr := e.snapshots.Diff(context.Background(), absWorkdir, startTree, endTree)
				if diffErr != nil {
					snapshotWarning = diffErr.Error()
				}
				stepSnap = &StepSnapshot{
					Start: startTree,
					End:   endTree,
					Files: diffs,
				}
			}
		}
		if snapshotWarning != "" {
			if stepSnap == nil {
				stepSnap = &StepSnapshot{Start: startTree}
			}
			stepSnap.Warning = snapshotWarning
		}

		allParts := append(llmResp.Parts, resultParts...)
		usageCopy := llmResp.Usage
		asstMsg := Message{
			ID:        asstMsgID,
			SessionID: sessionID,
			Role:      "assistant",
			Agent:     sessSnap.Agent,
			Model:     prov.Model,
			Parts:     allParts,
			Runtime:   runtime,
			Finish:    llmResp.Finish,
			Usage:     &usageCopy,
			Budget:    owned.meter.snapshot(),
			Snapshot:  stepSnap,
			CreatedAt: time.Now().UnixMilli(),
		}
		if ctx.Err() != nil {
			asstMsg.Finish = "aborted"
		}

		var totalUsage Usage
		var persistErr error
		e.mu.Lock()
		if cur := e.sessionLocked(sessionID); cur != nil {
			putStepMessage(cur, asstMsg)
			cur.TotalUsage.Add(llmResp.Usage)
			if llmResp.Usage.InputTokens > 0 {
				cur.LastInputToks = llmResp.Usage.InputTokens
			}
			cur.UpdatedAt = asstMsg.CreatedAt
			contextState = activeContext(cur, prov, contextOverhead(sysPrompts, tools))
			contextState.LastInput = llmResp.Usage.InputTokens
			if llmResp.Usage.InputTokens > 0 {
				// Inclusive input already includes cache reads; never add them again.
				exactPlusNew := llmResp.Usage.InputTokens + llmResp.Usage.OutputTokens + EstimateMessagesTokens([]Message{{Parts: resultParts}})
				if exactPlusNew > contextState.Tokens {
					contextState.Tokens = exactPlusNew
				}
			}
			cur.Context = contextState
			totalUsage = cur.TotalUsage
			persistErr = e.persistSessionLocked(cur)
		}
		e.mu.Unlock()

		msgCopy := asstMsg
		var stepDiffs []FileDiff
		if stepSnap != nil {
			stepDiffs = stepSnap.Files
		}
		e.broadcast(StreamEvent{
			Type:       "step.finish",
			SessionID:  sessionID,
			MessageID:  asstMsg.ID,
			Message:    &msgCopy,
			Diffs:      stepDiffs,
			Usage:      &usageCopy,
			TotalUsage: &totalUsage,
			Runtime:    runtime,
			Context:    contextState,
			Budget:     owned.meter.snapshot(),
		})
		if persistErr != nil {
			e.recordError(sessionID, prov.Model, "步骤结果保存失败，任务已暂停："+persistErr.Error())
			return
		}

		// The next iteration records a time-budget stop even when the deadline
		// expired during tool execution rather than during the model stream.
		if ctx.Err() != nil {
			continue
		}
		// Continue loop if model made tool calls or user sent steering inbox messages
		idleBoundary = len(toolCalls) == 0
		if idleBoundary {
			// Admission and deciding to go idle share the same lock.
			e.mu.Lock()
			ar := e.running[sessionID]
			done := ar == nil || (len(ar.inbox) == 0 && len(ar.queued) == 0)
			if done {
				e.finishRunLocked(sessionID, owned)
			}
			e.mu.Unlock()
			if done {
				return
			}
		}
	}
}

func (e *Env) recordAbortedPartial(sessionID, messageID, agentMode string, prov ProviderConfig, sysPrompts []string, tools []ToolDef, response LLMResponse) {
	if messageID == "" {
		messageID = NewID("msg")
	}
	usageCopy := response.Usage
	rt := runtimeInfo(prov)
	msg := Message{
		ID:        messageID,
		SessionID: sessionID,
		Role:      "assistant",
		Agent:     agentMode,
		Model:     prov.Model,
		Runtime:   rt,
		Parts:     response.Parts,
		Finish:    "aborted",
		CreatedAt: time.Now().UnixMilli(),
	}
	if usageCopy.TotalTokens > 0 || usageCopy.InputTokens > 0 || usageCopy.OutputTokens > 0 {
		msg.Usage = &usageCopy
	}
	var contextState *ContextInfo
	var totalUsage Usage
	var budget *RunBudgetState
	e.mu.Lock()
	if s := e.sessionLocked(sessionID); s != nil {
		if ar := e.running[sessionID]; ar != nil {
			budget = ar.meter.snapshot()
			msg.Budget = budget
			s.Budget = budget
		}
		putStepMessage(s, msg)
		s.TotalUsage.Add(usageCopy)
		if usageCopy.InputTokens > 0 {
			s.LastInputToks = usageCopy.InputTokens
		}
		s.Runtime = rt
		s.UpdatedAt = msg.CreatedAt
		contextState = activeContext(s, prov, contextOverhead(sysPrompts, tools))
		s.Context = contextState
		totalUsage = s.TotalUsage
		_ = e.persistSessionLocked(s)
	}
	e.mu.Unlock()
	msgCopy := msg
	e.broadcast(StreamEvent{
		Type:       "step.finish",
		SessionID:  sessionID,
		MessageID:  msg.ID,
		Message:    &msgCopy,
		Usage:      &usageCopy,
		TotalUsage: &totalUsage,
		Runtime:    rt,
		Context:    contextState,
		Budget:     budget,
	})
}

func (e *Env) recordError(sessionID, model, errMsg string) {
	e.recordRunError(sessionID, model, "", errors.New(errMsg), LLMResponse{})
}

func (e *Env) recordRunError(sessionID, model, messageID string, err error, response LLMResponse) {
	if messageID == "" {
		messageID = NewID("msg")
	}
	msg := Message{
		ID:        messageID,
		SessionID: sessionID,
		Role:      "assistant",
		Model:     model,
		Finish:    "error",
		Error:     err.Error(),
		Parts:     response.Parts,
		CreatedAt: time.Now().UnixMilli(),
	}
	var limit *budgetError
	if errors.As(err, &limit) {
		msg.ErrorCode = "budget." + limit.kind
	}
	if response.Usage.TotalTokens > 0 {
		msg.Usage = &response.Usage
	}
	var total Usage
	e.mu.Lock()
	if s := e.sessionLocked(sessionID); s != nil {
		if ar := e.running[sessionID]; ar != nil {
			msg.Runtime = runtimeInfo(ar.provider)
			msg.Model = ar.provider.Model
			msg.Budget = ar.meter.snapshot()
			s.Runtime = msg.Runtime
			s.Budget = msg.Budget
		}
		msg.Agent = s.Agent
		s.Messages = append(s.Messages, msg)
		s.TotalUsage.Add(response.Usage)
		total = s.TotalUsage
		s.UpdatedAt = msg.CreatedAt
		_ = e.persistSessionLocked(s)
	}
	e.mu.Unlock()

	msgCopy := msg
	e.broadcast(StreamEvent{
		Type:       "session.error",
		SessionID:  sessionID,
		MessageID:  msg.ID,
		Error:      msg.Error,
		Message:    &msgCopy,
		Runtime:    msg.Runtime,
		Budget:     msg.Budget,
		TotalUsage: &total,
	})
}

func (e *Env) runChildSubagent(ctx context.Context, parent *Session, prov ProviderConfig, agentType, desc, prompt, parentCallID string, depth int) (string, string, error) {
	if parent.ParentID != "" || depth != 1 {
		return "", "", errors.New("子代理不能继续创建子代理")
	}
	e.mu.Lock()
	run := e.running[parent.ID]
	persisted := e.sessionLocked(parent.ID)
	valid := run != nil && persisted != nil && persisted.ParentID == ""
	e.mu.Unlock()
	if !valid {
		return "", "", errors.New("主任务已经停止或不是主会话")
	}
	meter := run.meter
	policy := meter.config.Subagents.resolved()
	if policy.ReadOnly && agentType != "explore" {
		return "", "", errors.New("此项目仅允许只读子代理")
	}
	release, err := meter.acquireChild(ctx)
	if err != nil {
		return "", "", err
	}
	defer release()
	now := time.Now().UnixMilli()
	childProv := prov
	if run.subagentProvider != nil && strings.TrimSpace(run.subagentProvider.Model) != "" {
		childProv = *run.subagentProvider
	}
	childPermMode := parent.PermissionMode
	if run.subagentPermMode == "ask" || run.subagentPermMode == "auto" || run.subagentPermMode == "full_access" {
		childPermMode = run.subagentPermMode
	}
	switch policy.PermissionMode {
	case "ask", "auto", "full_access":
		childPermMode = policy.PermissionMode
	case "readOnly":
		agentType = "explore"
		childPermMode = "ask"
	}
	childRules := append([]PermissionRule(nil), parent.PermissionRules...)
	childRules = append(childRules, run.subagentPermRules...)
	if policy.AllowNetwork != nil && !*policy.AllowNetwork {
		childRules = append(childRules, PermissionRule{
			Action:   "network",
			Resource: "*",
			Effect:   "deny",
			Agent:    "subagent",
		})
	}
	if policy.AllowShell != nil && !*policy.AllowShell {
		childRules = append(childRules, PermissionRule{
			Action:   "shell",
			Resource: "*",
			Effect:   "deny",
			Agent:    "subagent",
		})
	}
	child := &Session{
		ID:              NewID("ses"),
		ParentID:        parent.ID,
		Title:           desc,
		Root:            parent.Root,
		Workdir:         parent.Workdir,
		Agent:           agentType,
		PermissionMode:  childPermMode,
		PermissionRules: childRules,
		Model:           childProv.Model,
		Protocol:        childProv.Protocol,
		Messages: []Message{
			{
				ID:        NewID("msg"),
				SessionID: "",
				Role:      "user",
				Agent:     agentType,
				Parts: []Part{
					{
						Type: "text",
						ID:   NewID("prt"),
						Text: "You are a subagent spawned by another session.\n" + prompt,
					},
				},
				CreatedAt: now,
			},
		},
		CreatedAt: now,
		UpdatedAt: now,
	}
	child.Messages[0].SessionID = child.ID

	childCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	e.mu.Lock()
	if ctx.Err() != nil || e.running[parent.ID] != run {
		e.mu.Unlock()
		return "", "", errors.New("主任务已经停止")
	}
	e.sessions[child.ID] = child
	child.Budget = meter.snapshot()
	childRun := &activeRun{
		cancel:   cancel,
		provider: childProv,
		meter:    meter,
	}
	e.running[child.ID] = childRun
	if err := e.persistSessionLocked(child); err != nil {
		delete(e.running, child.ID)
		delete(e.sessions, child.ID)
		e.mu.Unlock()
		return "", "", err
	}
	e.mu.Unlock()
	input, _ := json.Marshal(map[string]string{"agent": agentType, "description": desc})
	e.broadcast(StreamEvent{Type: "tool.running", SessionID: parent.ID, ToolCallID: parentCallID, ToolName: "subagent", Input: input, Metadata: map[string]any{"child_session_id": child.ID, "agent": agentType, "description": desc, "started_at": now}})

	e.runLoop(childCtx, child.ID, depth)

	e.mu.Lock()
	finished := e.sessionLocked(child.ID)
	stopped := childRun.stopRequested
	var report string
	var runErr string
	if finished != nil {
		for i := len(finished.Messages) - 1; i >= 0; i-- {
			m := finished.Messages[i]
			if m.Role == "assistant" {
				if m.Error != "" {
					runErr = m.Error
				}
				var texts []string
				for _, p := range m.Parts {
					if p.Type == "text" && strings.TrimSpace(p.Text) != "" {
						texts = append(texts, p.Text)
					}
				}
				if len(texts) > 0 {
					report = strings.Join(texts, "\n\n")
					break
				}
			}
		}
	}
	e.mu.Unlock()

	if ctx.Err() != nil {
		return report, child.ID, ctx.Err()
	}
	if stopped {
		return report, child.ID, fmt.Errorf("子代理已停止: %w", context.Canceled)
	}
	if runErr != "" {
		return "", child.ID, errors.New(runErr)
	}
	if report == "" {
		report = "(Subagent completed with no text report)"
	}
	return report, child.ID, nil
}

// CompactSession triggers manual compaction on an idle session.
func (e *Env) CompactSession(ctx context.Context, sessionID string, prov ProviderConfig) (Message, error) {
	e.init()
	e.mu.Lock()
	s := e.sessionLocked(sessionID)
	if s == nil {
		e.mu.Unlock()
		return Message{}, fmt.Errorf("session not found: %s", sessionID)
	}
	if e.running[sessionID] != nil || e.maintenance[sessionID] != nil || e.maintenance["snapshots:gc"] != nil {
		e.mu.Unlock()
		return Message{}, errors.New("cannot compact while session is running or under maintenance")
	}
	_, _, absWorkdir, err := e.resolveWorkspace(s.Root, s.Workdir)
	if err != nil {
		e.mu.Unlock()
		return Message{}, err
	}
	ctx, cancel := context.WithCancel(ctx)
	e.maintenance[sessionID] = cancel
	e.mu.Unlock()
	defer e.finishMaintenance(sessionID, cancel)
	return e.compactInternal(ctx, sessionID, prov, absWorkdir, false)
}

func (e *Env) finishMaintenance(id string, cancel context.CancelFunc) {
	cancel()
	e.mu.Lock()
	delete(e.maintenance, id)
	e.mu.Unlock()
}

func (e *Env) compactInternal(ctx context.Context, sessionID string, prov ProviderConfig, absWorkdir string, overflow bool) (Message, error) {
	var prepErr error
	prov, prepErr = prepareSubscription(prov)
	if prepErr != nil {
		return Message{}, prepErr
	}
	e.mu.Lock()
	s := e.sessionLocked(sessionID)
	if s == nil {
		e.mu.Unlock()
		return Message{}, fmt.Errorf("session not found: %s", sessionID)
	}
	snap := cloneSession(s)
	e.mu.Unlock()

	e.broadcast(StreamEvent{
		Type:      "compaction.start",
		SessionID: sessionID,
	})

	e.mu.Lock()
	var meter *runMeter
	if run := e.running[sessionID]; run != nil {
		meter = run.meter
	}
	e.mu.Unlock()
	if meter == nil {
		cfg, _, err := loadExtensionConfig(absWorkdir)
		if err != nil {
			return Message{}, err
		}
		meter = newRunMeter(cfg)
	}
	compMsg, err := RunCompaction(ctx, &snap, prov, absWorkdir, overflow, e.proxyFor(prov), e.loadAttachment, func(delta string) {
		e.broadcast(StreamEvent{
			Type:      "compaction.delta",
			SessionID: sessionID,
			Delta:     delta,
		})
	}, meter)
	if err != nil && !overflow && IsContextOverflowError(err) && ctx.Err() == nil {
		compMsg, err = RunCompaction(ctx, &snap, prov, absWorkdir, true, e.proxyFor(prov), e.loadAttachment, func(delta string) {
			e.broadcast(StreamEvent{
				Type:      "compaction.delta",
				SessionID: sessionID,
				Delta:     delta,
			})
		}, meter)
	}
	if err != nil {
		e.broadcast(StreamEvent{
			Type:      "compaction.error",
			SessionID: sessionID,
			Error:     err.Error(),
		})
		return Message{}, err
	}

	var contextState *ContextInfo
	var totalUsage Usage
	compMsg.Runtime = runtimeInfo(prov)
	e.mu.Lock()
	if ctx.Err() != nil {
		err = ctx.Err()
	} else if cur := e.sessionLocked(sessionID); cur != nil {
		before := *cur
		cur.Messages = append(cur.Messages, compMsg)
		if compMsg.Usage != nil {
			cur.TotalUsage.Add(*compMsg.Usage)
		}
		cur.LastInputToks = EstimateMessagesTokens(BuildActiveHistory(cur.Messages))
		overhead := 0
		if cur.Context != nil {
			overhead = cur.Context.Overhead
		}
		contextState = activeContext(cur, prov, overhead)
		contextState.LastInput = 0 // pre-compaction input does not describe the checkpoint
		cur.Context = contextState
		cur.Runtime = compMsg.Runtime
		totalUsage = cur.TotalUsage
		cur.UpdatedAt = compMsg.CreatedAt
		if err = e.persistSessionLocked(cur); err != nil {
			*cur = before
		}
	} else {
		err = fmt.Errorf("session not found: %s", sessionID)
	}
	e.mu.Unlock()
	if err != nil {
		e.broadcast(StreamEvent{Type: "compaction.error", SessionID: sessionID, Error: err.Error()})
		return Message{}, err
	}

	cp := compMsg
	e.broadcast(StreamEvent{
		Type:       "compaction.done",
		SessionID:  sessionID,
		MessageID:  compMsg.ID,
		Message:    &cp,
		Context:    contextState,
		TotalUsage: &totalUsage,
		Runtime:    compMsg.Runtime,
	})
	return compMsg, nil
}

// RevertSession ports OpenCode's SessionRevert: restores files changed in steps after
// targetMessageID (or from targetMessageID onward if inclusive) using shadow-git trees,
// and truncates later messages from the session.
func (e *Env) RevertSession(ctx context.Context, sessionID, messageID string, restoreFiles bool) (Session, int, error) {
	e.init()
	if e.recoveryErr != nil {
		return Session{}, 0, e.recoveryErr
	}

	e.mu.Lock()
	e.waitSessionLocked(sessionID)
	if e.maintenance[sessionID] != nil || e.maintenance["snapshots:gc"] != nil {
		e.mu.Unlock()
		return Session{}, 0, errors.New("会话正在压缩或回退，请等待完成")
	}
	if e.running[sessionID] != nil {
		e.mu.Unlock()
		e.StopSession(sessionID)
		return Session{}, 0, errors.New("正在停止会话，请等待任务结束后重试回退")
	}
	s := e.sessionLocked(sessionID)
	if s == nil {
		e.mu.Unlock()
		return Session{}, 0, fmt.Errorf("session not found: %s", sessionID)
	}
	idx := -1
	for i, m := range s.Messages {
		if m.ID == messageID {
			idx = i
			break
		}
	}
	if idx < 0 {
		e.mu.Unlock()
		return Session{}, 0, fmt.Errorf("message not found: %s", messageID)
	}

	// Revert everything from `idx` onward if it's a user prompt or assistant turn
	fileToTree := map[string]string{}
	fileToEnd := map[string]string{}
	for i := idx; i < len(s.Messages); i++ {
		m := s.Messages[i]
		if m.Snapshot != nil && m.Snapshot.Start != "" {
			for _, f := range m.Snapshot.Files {
				if _, seen := fileToTree[f.File]; !seen {
					fileToTree[f.File] = m.Snapshot.Start
				}
				fileToEnd[f.File] = m.Snapshot.End
			}
		}
	}
	_, _, absWorkdir, err := e.resolveWorkspace(s.Root, s.Workdir)
	if err != nil {
		e.mu.Unlock()
		return Session{}, 0, err
	}
	ctx, cancel := context.WithCancel(ctx)
	e.maintenance[sessionID] = cancel
	e.mu.Unlock()
	defer e.finishMaintenance(sessionID, cancel)

	restoredCount := 0
	var changes []filetxn.Change
	if restoreFiles && len(fileToTree) > 0 {
		changes, err = e.snapshots.PlanRestore(ctx, absWorkdir, fileToTree, fileToEnd)
		if err != nil {
			return Session{}, 0, err
		}
	}

	e.mu.Lock()
	if err := ctx.Err(); err != nil {
		e.mu.Unlock()
		return Session{}, restoredCount, err
	}
	s = e.sessionLocked(sessionID)
	if s == nil {
		e.mu.Unlock()
		return Session{}, 0, fmt.Errorf("session not found: %s", sessionID)
	}
	next := *s
	s = &next
	if idx <= len(s.Messages) {
		s.Messages = append([]Message(nil), s.Messages[:idx]...)
	}
	for len(s.Messages) > 0 {
		last := s.Messages[len(s.Messages)-1]
		if last.Role == "user" && len(last.Parts) == 1 && strings.HasPrefix(last.Parts[0].Text, "<system-reminder>") {
			s.Messages = s.Messages[:len(s.Messages)-1]
			continue
		}
		break
	}
	s.Todos = revertTodosFromMessages(s.Messages)
	for i := len(s.Messages) - 1; i >= 0; i-- {
		if s.Messages[i].Agent != "" {
			s.Agent = s.Messages[i].Agent
			break
		}
	}
	s.LastInputToks = EstimateMessagesTokens(BuildActiveHistory(s.Messages))
	if s.Context != nil {
		cp := *s.Context
		cp.Tokens = s.LastInputToks + cp.Overhead
		cp.LastInput = 0
		cp.Estimated = true
		s.Context = &cp
	}
	s.Runtime = nil
	for i := len(s.Messages) - 1; i >= 0; i-- {
		if s.Messages[i].Runtime != nil {
			s.Runtime = s.Messages[i].Runtime
			break
		}
	}
	s.UpdatedAt = time.Now().UnixMilli()
	// Persist the session checkpoint in the same undo journal as the files.
	// Memory is published only after the complete batch has a commit marker.
	if err := e.commitSessionRevertLocked(ctx, s, absWorkdir, changes); err != nil {
		e.mu.Unlock()
		return Session{}, 0, fmt.Errorf("revert transaction failed: %w", err)
	}
	e.sessions[sessionID] = s
	if restoreFiles {
		restoredCount = len(fileToTree)
	}
	out := cloneSession(s)
	e.mu.Unlock()
	if e.Audit != nil {
		e.Audit.Write("ai.revert", map[string]any{"session": sessionID, "files": restoredCount})
	}

	e.broadcast(StreamEvent{
		Type:      "session.reverted",
		SessionID: sessionID,
		MessageID: messageID,
	})
	return out, restoredCount, nil
}

func revertTodosFromMessages(msgs []Message) []TodoItem {
	for i := len(msgs) - 1; i >= 0; i-- {
		for j := len(msgs[i].Parts) - 1; j >= 0; j-- {
			p := msgs[i].Parts[j]
			if p.Type == "tool-result" && p.ToolName == "todowrite" && !p.IsError {
				if raw, ok := p.Metadata["todos"]; ok {
					b, err := json.Marshal(raw)
					if err == nil {
						var items []TodoItem
						if json.Unmarshal(b, &items) == nil {
							return items
						}
					}
				}
			}
		}
	}
	return nil
}

func truncateShort(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}
