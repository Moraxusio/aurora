//go:build linux

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"aurora3/internal/paths"
)

const maxRunnerSteps = 60

type activeRun struct {
	cancel   context.CancelFunc
	inbox    []InboxItem
	provider ProviderConfig
}

// Env is the state and dependencies of the "ai" service on the agent.
type Env struct {
	StateDir string
	Roots    []Root
	Audit    Auditor
	Proxy    func() map[string]string

	once      sync.Once
	mu        sync.Mutex
	sessions  map[string]*Session
	running   map[string]*activeRun
	subs      map[chan StreamEvent]struct{}
	perms     *PermissionGate
	snapshots *SnapshotManager
}

func (e *Env) init() {
	e.once.Do(func() {
		e.sessions = map[string]*Session{}
		e.running = map[string]*activeRun{}
		e.subs = map[chan StreamEvent]struct{}{}
		e.perms = NewPermissionGate()
		e.snapshots = NewSnapshotManager(e.StateDir)
		e.loadAllFromDisk()
	})
}

func (e *Env) sessionsDir() string {
	if e.StateDir == "" {
		return ""
	}
	return filepath.Join(e.StateDir, "ai", "sessions")
}

func (e *Env) loadAllFromDisk() {
	dir := e.sessionsDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, ent := range entries {
		if ent.IsDir() || !strings.HasSuffix(ent.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, ent.Name()))
		if err != nil {
			continue
		}
		var s Session
		if json.Unmarshal(b, &s) == nil && s.ID != "" {
			e.sessions[s.ID] = &s
		}
	}
}

func (e *Env) persistSessionLocked(s *Session) error {
	dir := e.sessionsDir()
	if dir == "" {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	cp := cloneSession(s)
	b, err := json.Marshal(&cp)
	if err != nil {
		return err
	}
	target := filepath.Join(dir, s.ID+".json")
	return atomicWriteFile(target, b, 0o600)
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
	chans := make([]chan StreamEvent, 0, len(e.subs))
	for ch := range e.subs {
		chans = append(chans, ch)
	}
	e.mu.Unlock()

	for _, ch := range chans {
		select {
		case ch <- ev:
		default:
			// Drop oldest delta if client reads slowly so stream never deadlocks the runner
			if ev.Type != "text.delta" && ev.Type != "reasoning.delta" {
				select {
				case <-ch:
				default:
				}
				select {
				case ch <- ev:
				default:
				}
			}
		}
	}
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
		out = append(out, SessionSummary{
			ID:                s.ID,
			ParentID:          s.ParentID,
			Title:             s.Title,
			Pinned:            s.Pinned,
			Root:              s.Root,
			Workdir:           s.Workdir,
			Agent:             s.Agent,
			Model:             s.Model,
			Preview:           sessionPreview(s),
			Running:           isRun,
			PendingPermission: e.perms.PendingForSession(s.ID),
			MessageCount:      len(s.Messages),
			CreatedAt:         s.CreatedAt,
			UpdatedAt:         s.UpdatedAt,
		})
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
	s, ok := e.sessions[id]
	if !ok {
		e.mu.Unlock()
		return SessionSummary{}, fmt.Errorf("session not found: %s", id)
	}
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
	_ = e.persistSessionLocked(s)
	sum := SessionSummary{ID: s.ID, Title: s.Title, Pinned: s.Pinned, Root: s.Root, Workdir: s.Workdir, Agent: s.Agent, Model: s.Model, MessageCount: len(s.Messages), CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt}
	e.mu.Unlock()
	e.broadcast(StreamEvent{Type: "session.title", SessionID: id, Title: sum.Title})
	return sum, nil
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
	e.init()
	words := strings.Fields(strings.ToLower(query))
	if len(words) == 0 {
		return nil
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	var hits []SearchHit
	for _, s := range e.sessions {
		if s.ParentID != "" {
			continue
		}
		all := strings.ToLower(s.Title)
		var texts []struct{ id, text string }
		for _, m := range s.Messages {
			for _, p := range m.Parts {
				if (p.Type == "text" || p.Type == "compaction") && p.Text != "" && !strings.HasPrefix(p.Text, "<system-reminder>") {
					all += "\n" + strings.ToLower(p.Text)
					texts = append(texts, struct{ id, text string }{m.ID, p.Text})
				}
			}
		}
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
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].UpdatedAt > hits[j].UpdatedAt })
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits
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
	s, ok := e.sessions[id]
	if !ok {
		return Session{}, false, nil, fmt.Errorf("session not found: %s", id)
	}
	_, isRun := e.running[id]
	return cloneSession(s), isRun, e.perms.PendingForSession(id), nil
}

func (e *Env) DeleteSession(id string) error {
	e.init()
	e.StopSession(id)

	e.mu.Lock()
	defer e.mu.Unlock()
	if _, ok := e.sessions[id]; !ok {
		return nil
	}
	// Also delete any child subagent sessions
	var toDelete []string
	toDelete = append(toDelete, id)
	for cid, cs := range e.sessions {
		if cs.ParentID == id {
			toDelete = append(toDelete, cid)
		}
	}
	dir := e.sessionsDir()
	for _, did := range toDelete {
		delete(e.sessions, did)
		if dir != "" {
			_ = os.Remove(filepath.Join(dir, did+".json"))
		}
	}
	return nil
}

func (e *Env) StopSession(id string) bool {
	e.init()
	e.perms.CancelSession(id)
	e.mu.Lock()
	ar, ok := e.running[id]
	e.mu.Unlock()
	if ok && ar.cancel != nil {
		ar.cancel()
		return true
	}
	return false
}

func (e *Env) StopAll() {
	e.init()
	e.mu.Lock()
	ids := make([]string, 0, len(e.running))
	for id := range e.running {
		ids = append(ids, id)
	}
	e.mu.Unlock()
	for _, id := range ids {
		e.StopSession(id)
	}
}

func (e *Env) updateTodos(sessionID string, todos []TodoItem) {
	e.mu.Lock()
	s, ok := e.sessions[sessionID]
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
	SessionID      string              `json:"session_id,omitempty"`
	Root           string              `json:"root,omitempty"`
	Workdir        string              `json:"workdir,omitempty"`
	Agent          string              `json:"agent,omitempty"`           // "build" | "plan"
	PermissionMode string              `json:"permission_mode,omitempty"` // "ask" | "auto"
	Text           string              `json:"text"`
	Attachments    []ContextAttachment `json:"attachments,omitempty"`
	Delivery       string              `json:"delivery,omitempty"` // "steer" | "queue"
	Provider       ProviderConfig      `json:"provider"`
}

// StartRun creates or resumes a session, enqueues the user prompt (supporting live steering
// if already running, just like OpenCode's inbox), and spawns the background runner goroutine.
func (e *Env) StartRun(in RunInput) (SessionSummary, error) {
	e.init()
	if strings.TrimSpace(in.Text) == "" && len(in.Attachments) == 0 {
		return SessionSummary{}, errors.New("prompt text must not be empty")
	}
	if strings.TrimSpace(in.Provider.Model) == "" {
		return SessionSummary{}, errors.New("model must not be empty")
	}

	agentMode := strings.ToLower(strings.TrimSpace(in.Agent))
	if agentMode != "plan" && agentMode != "build" {
		agentMode = "build"
	}
	permMode := strings.ToLower(strings.TrimSpace(in.PermissionMode))
	if permMode != "auto" && permMode != "ask" {
		permMode = "ask"
	}

	e.mu.Lock()
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
		s = &Session{
			ID:             NewID("ses"),
			Title:          fallbackTitle(in.Text),
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

	prevAgent := s.Agent
	s.Agent = agentMode
	s.PermissionMode = permMode
	s.Model = in.Provider.Model
	s.Protocol = in.Provider.Protocol
	s.UpdatedAt = time.Now().UnixMilli()

	// If already running, push into activeRun.inbox for OpenCode-style live steering!
	if ar, busy := e.running[s.ID]; busy {
		ar.provider = in.Provider
		ar.inbox = append(ar.inbox, InboxItem{
			ID:          NewID("inb"),
			Text:        in.Text,
			Agent:       agentMode,
			Delivery:    in.Delivery,
			Attachments: in.Attachments,
			CreatedAt:   time.Now().UnixMilli(),
		})
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
		e.mu.Unlock()
		return sum, nil
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
		Parts:     []Part{{Type: "text", ID: NewID("prt"), Text: formatUserContent(in.Text, in.Attachments)}},
		CreatedAt: time.Now().UnixMilli(),
	}
	s.Messages = append(s.Messages, userMsg)
	_ = e.persistSessionLocked(s)

	runCtx, cancel := context.WithCancel(context.Background())
	ar := &activeRun{
		cancel:   cancel,
		provider: in.Provider,
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
	})

	if isFirstPrompt && strings.TrimSpace(firstPromptText) != "" {
		go e.generateTitleAsync(sid, firstPromptText, provCopy)
	}

	go e.runLoop(runCtx, sid, 0)
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

func (e *Env) generateTitleAsync(sessionID, promptText string, cfg ProviderConfig) {
	cctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()

	temp := 0.3
	resp, err := StreamLLM(cctx, LLMRequest{
		SessionID: sessionID,
		Initiator: "agent",
		Provider: ProviderConfig{
			ID:       cfg.ID,
			Protocol: cfg.Protocol,
			BaseURL:  cfg.BaseURL,
			APIKey:   cfg.APIKey,
			AuthMode: cfg.AuthMode,
			Model:    cfg.Model,
			Headers:  cfg.Headers,
			UseProxy: cfg.UseProxy,
		},
		System:      []string{PromptTitle},
		Messages:    []Message{{ID: NewID("msg"), Role: "user", Parts: []Part{{Type: "text", Text: promptText}}}},
		MaxTokens:   80,
		Temperature: &temp,
	}, e.Proxy, nil)
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
	s := e.sessions[sessionID]
	if s != nil {
		s.Title = title
		s.UpdatedAt = time.Now().UnixMilli()
		_ = e.persistSessionLocked(s)
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

func (e *Env) runLoop(ctx context.Context, sessionID string, depth int) {
	defer func() {
		e.perms.CancelSession(sessionID)
		e.mu.Lock()
		delete(e.running, sessionID)
		s := e.sessions[sessionID]
		if s != nil {
			_ = e.persistSessionLocked(s)
		}
		e.mu.Unlock()
		e.broadcast(StreamEvent{
			Type:      "session.status",
			SessionID: sessionID,
			Status:    "idle",
		})
	}()

	type recentCall struct {
		name string
		args string
	}
	var lastCalls []recentCall

	for step := 0; step < maxRunnerSteps; step++ {
		if ctx.Err() != nil {
			return
		}

		e.mu.Lock()
		s := e.sessions[sessionID]
		ar := e.running[sessionID]
		if s == nil || ar == nil {
			e.mu.Unlock()
			return
		}
		// Drain any steering inbox messages submitted while running
		if len(ar.inbox) > 0 {
			for _, item := range ar.inbox {
				if item.Agent != "" && (item.Agent == "build" || item.Agent == "plan") {
					s.Agent = item.Agent
				}
				um := Message{
					ID:        NewID("msg"),
					SessionID: s.ID,
					Role:      "user",
					Agent:     s.Agent,
					Parts:     []Part{{Type: "text", ID: NewID("prt"), Text: formatUserContent(item.Text, item.Attachments)}},
					CreatedAt: item.CreatedAt,
				}
				s.Messages = append(s.Messages, um)
				umCopy := um
				go e.broadcast(StreamEvent{
					Type:      "message.added",
					SessionID: s.ID,
					MessageID: um.ID,
					Message:   &umCopy,
				})
			}
			ar.inbox = nil
			_ = e.persistSessionLocked(s)
		}
		sessSnap := cloneSession(s)
		prov := ar.provider
		e.mu.Unlock()

		rt, _, absWorkdir, err := e.resolveWorkspace(sessSnap.Root, sessSnap.Workdir)
		if err != nil {
			e.recordError(sessionID, prov.Model, err.Error())
			return
		}

		// Auto-compaction check before issuing step request (matching OpenCode's runner)
		if depth == 0 && ShouldAutoCompact(&sessSnap, prov) {
			if _, cerr := e.compactInternal(ctx, sessionID, prov, absWorkdir, false); cerr == nil {
				e.mu.Lock()
				if cur := e.sessions[sessionID]; cur != nil {
					sessSnap = cloneSession(cur)
				}
				e.mu.Unlock()
			}
		}

		tools := ToolDefinitions(sessSnap.Agent, depth)
		toolNames := make([]string, len(tools))
		for i, t := range tools {
			toolNames[i] = t.Name
		}
		sysPrompts := BuildSystemPrompts(sessSnap.Agent, prov, absWorkdir, toolNames)
		activeMsgs := BuildActiveHistory(sessSnap.Messages)

		initiator := "user"
		if step > 0 || depth > 0 {
			initiator = "agent"
		}

		startTree := ""
		if depth == 0 && sessSnap.Agent == "build" {
			startTree = e.snapshots.Capture(ctx, absWorkdir)
		}

		asstMsgID := NewID("msg")
		e.broadcast(StreamEvent{
			Type:      "step.start",
			SessionID: sessionID,
			MessageID: asstMsgID,
		})

		llmResp, llmErr := StreamLLM(ctx, LLMRequest{
			SessionID:  sessionID,
			AffinityID: sessSnap.ParentID,
			Initiator:  initiator,
			Provider:   prov,
			System:     sysPrompts,
			Messages:   activeMsgs,
			Tools:      tools,
		}, e.Proxy, func(d LLMDelta) {
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
		})

		if llmErr != nil {
			if ctx.Err() != nil {
				return
			}
			// Context overflow recovery: run overflow compaction once and retry step!
			if depth == 0 && IsContextOverflowError(llmErr) {
				if _, cerr := e.compactInternal(ctx, sessionID, prov, absWorkdir, true); cerr == nil {
					continue
				}
			}
			e.recordError(sessionID, prov.Model, llmErr.Error())
			return
		}

		// Collect tool calls from assistant parts
		var toolCalls []Part
		for _, p := range llmResp.Parts {
			if p.Type == "tool-call" {
				toolCalls = append(toolCalls, p)
			}
		}

		// Execute tool calls sequentially (preserving snapshot & doom-loop determinism; read-only calls are fast)
		var resultParts []Part
		for _, call := range toolCalls {
			if ctx.Err() != nil {
				break
			}
			e.broadcast(StreamEvent{
				Type:       "tool.running",
				SessionID:  sessionID,
				MessageID:  asstMsgID,
				ToolCallID: call.ToolCallID,
				ToolName:   call.ToolName,
				Input:      call.Input,
			})

			// OpenCode 3-strike doom-loop detector
			sig := recentCall{name: call.ToolName, args: strings.TrimSpace(string(call.Input))}
			lastCalls = append(lastCalls, sig)
			if len(lastCalls) > 3 {
				lastCalls = lastCalls[len(lastCalls)-3:]
			}
			var execRes ToolExecResult
			if len(lastCalls) == 3 && lastCalls[0] == lastCalls[1] && lastCalls[1] == lastCalls[2] {
				q := PermissionQuestion{
					ID:        NewID("perm"),
					SessionID: sessionID,
					MessageID: asstMsgID,
					CallID:    call.ToolCallID,
					Tool:      call.ToolName,
					Action:    "doom_loop",
					Resource:  call.ToolName + " " + truncateShort(sig.args, 120),
					Reason:    "Agent invoked the exact same tool & arguments 3 times in a row. Continue anyway?",
				}
				if perr := e.perms.Ask(ctx, q, func(pq PermissionQuestion) {
					e.broadcast(StreamEvent{
						Type:       "permission.ask",
						SessionID:  sessionID,
						MessageID:  asstMsgID,
						ToolCallID: call.ToolCallID,
						Permission: &pq,
					})
				}); perr != nil {
					execRes = ToolExecResult{Output: perr.Error(), IsError: true}
				} else {
					lastCalls = nil
					execRes = executeTool(ctx, toolContext{
						env:        e,
						session:    &sessSnap,
						provider:   prov,
						rootPath:   rt.Path,
						absWorkdir: absWorkdir,
						messageID:  asstMsgID,
						callID:     call.ToolCallID,
						depth:      depth,
					}, call.ToolName, call.Input)
				}
			} else {
				execRes = executeTool(ctx, toolContext{
					env:        e,
					session:    &sessSnap,
					provider:   prov,
					rootPath:   rt.Path,
					absWorkdir: absWorkdir,
					messageID:  asstMsgID,
					callID:     call.ToolCallID,
					depth:      depth,
				}, call.ToolName, call.Input)
			}

			resPart := Part{
				Type:       "tool-result",
				ID:         NewID("prt"),
				ToolName:   call.ToolName,
				ToolCallID: call.ToolCallID,
				Output:     execRes.Output,
				IsError:    execRes.IsError,
				Metadata:   execRes.Metadata,
			}
			resultParts = append(resultParts, resPart)

			e.broadcast(StreamEvent{
				Type:       "tool.done",
				SessionID:  sessionID,
				MessageID:  asstMsgID,
				ToolCallID: call.ToolCallID,
				ToolName:   call.ToolName,
				Input:      call.Input,
				Output:     execRes.Output,
				IsError:    execRes.IsError,
				Metadata:   execRes.Metadata,
			})
		}

		// Capture end-of-step shadow-git snapshot if tools ran
		var stepSnap *StepSnapshot
		if startTree != "" && len(toolCalls) > 0 {
			endTree := e.snapshots.Capture(context.Background(), absWorkdir)
			if endTree != "" && endTree != startTree {
				diffs, _ := e.snapshots.Diff(context.Background(), absWorkdir, startTree, endTree)
				stepSnap = &StepSnapshot{
					Start: startTree,
					End:   endTree,
					Files: diffs,
				}
			}
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
			Finish:    llmResp.Finish,
			Usage:     &usageCopy,
			Snapshot:  stepSnap,
			CreatedAt: time.Now().UnixMilli(),
		}

		hasMoreInbox := false
		e.mu.Lock()
		if cur := e.sessions[sessionID]; cur != nil {
			cur.Messages = append(cur.Messages, asstMsg)
			cur.TotalUsage.Add(llmResp.Usage)
			if llmResp.Usage.InputTokens > 0 {
				cur.LastInputToks = llmResp.Usage.InputTokens
			}
			cur.UpdatedAt = asstMsg.CreatedAt
			_ = e.persistSessionLocked(cur)
		}
		if ar := e.running[sessionID]; ar != nil && len(ar.inbox) > 0 {
			hasMoreInbox = true
		}
		e.mu.Unlock()

		msgCopy := asstMsg
		var stepDiffs []FileDiff
		if stepSnap != nil {
			stepDiffs = stepSnap.Files
		}
		e.broadcast(StreamEvent{
			Type:      "step.finish",
			SessionID: sessionID,
			MessageID: asstMsg.ID,
			Message:   &msgCopy,
			Diffs:     stepDiffs,
			Usage:     &usageCopy,
		})

		if ctx.Err() != nil {
			return
		}
		// Continue loop if model made tool calls or user sent steering inbox messages
		if len(toolCalls) == 0 && !hasMoreInbox {
			return
		}
	}
}

func (e *Env) recordError(sessionID, model, errMsg string) {
	msg := Message{
		ID:        NewID("msg"),
		SessionID: sessionID,
		Role:      "assistant",
		Model:     model,
		Finish:    "error",
		Error:     errMsg,
		CreatedAt: time.Now().UnixMilli(),
	}
	e.mu.Lock()
	if s := e.sessions[sessionID]; s != nil {
		s.Messages = append(s.Messages, msg)
		s.UpdatedAt = msg.CreatedAt
		_ = e.persistSessionLocked(s)
	}
	e.mu.Unlock()

	msgCopy := msg
	e.broadcast(StreamEvent{
		Type:      "session.error",
		SessionID: sessionID,
		MessageID: msg.ID,
		Error:     errMsg,
		Message:   &msgCopy,
	})
}

func (e *Env) runChildSubagent(ctx context.Context, parent *Session, prov ProviderConfig, agentType, desc, prompt string, depth int) (string, string, error) {
	now := time.Now().UnixMilli()
	child := &Session{
		ID:             NewID("ses"),
		ParentID:       parent.ID,
		Title:          desc,
		Root:           parent.Root,
		Workdir:        parent.Workdir,
		Agent:          agentType,
		PermissionMode: parent.PermissionMode,
		Model:          prov.Model,
		Protocol:       prov.Protocol,
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
	e.sessions[child.ID] = child
	e.running[child.ID] = &activeRun{
		cancel:   cancel,
		provider: prov,
	}
	_ = e.persistSessionLocked(child)
	e.mu.Unlock()

	e.runLoop(childCtx, child.ID, depth)

	e.mu.Lock()
	finished := e.sessions[child.ID]
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

	if report == "" && runErr != "" {
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
	s := e.sessions[sessionID]
	if s == nil {
		e.mu.Unlock()
		return Message{}, fmt.Errorf("session not found: %s", sessionID)
	}
	if _, busy := e.running[sessionID]; busy {
		e.mu.Unlock()
		return Message{}, errors.New("cannot compact while session is running")
	}
	_, _, absWorkdir, err := e.resolveWorkspace(s.Root, s.Workdir)
	e.mu.Unlock()
	if err != nil {
		return Message{}, err
	}
	return e.compactInternal(ctx, sessionID, prov, absWorkdir, false)
}

func (e *Env) compactInternal(ctx context.Context, sessionID string, prov ProviderConfig, absWorkdir string, overflow bool) (Message, error) {
	e.mu.Lock()
	s := e.sessions[sessionID]
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

	compMsg, err := RunCompaction(ctx, &snap, prov, absWorkdir, overflow, e.Proxy, func(delta string) {
		e.broadcast(StreamEvent{
			Type:      "compaction.delta",
			SessionID: sessionID,
			Delta:     delta,
		})
	})
	if err != nil {
		e.broadcast(StreamEvent{
			Type:      "compaction.error",
			SessionID: sessionID,
			Error:     err.Error(),
		})
		return Message{}, err
	}

	e.mu.Lock()
	if cur := e.sessions[sessionID]; cur != nil {
		cur.Messages = append(cur.Messages, compMsg)
		if compMsg.Usage != nil {
			cur.TotalUsage.Add(*compMsg.Usage)
		}
		cur.LastInputToks = EstimateMessagesTokens(BuildActiveHistory(cur.Messages))
		cur.UpdatedAt = compMsg.CreatedAt
		_ = e.persistSessionLocked(cur)
	}
	e.mu.Unlock()

	cp := compMsg
	e.broadcast(StreamEvent{
		Type:      "compaction.done",
		SessionID: sessionID,
		MessageID: compMsg.ID,
		Message:   &cp,
	})
	return compMsg, nil
}

// RevertSession ports OpenCode's SessionRevert: restores files changed in steps after
// targetMessageID (or from targetMessageID onward if inclusive) using shadow-git trees,
// and truncates later messages from the session.
func (e *Env) RevertSession(ctx context.Context, sessionID, messageID string, restoreFiles bool) (Session, int, error) {
	e.init()
	e.StopSession(sessionID)

	e.mu.Lock()
	s := e.sessions[sessionID]
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
	for i := idx; i < len(s.Messages); i++ {
		m := s.Messages[i]
		if m.Snapshot != nil && m.Snapshot.Start != "" {
			for _, f := range m.Snapshot.Files {
				if _, seen := fileToTree[f.File]; !seen {
					fileToTree[f.File] = m.Snapshot.Start
				}
			}
		}
	}
	_, _, absWorkdir, err := e.resolveWorkspace(s.Root, s.Workdir)
	e.mu.Unlock()
	if err != nil {
		return Session{}, 0, err
	}

	restoredCount := 0
	if restoreFiles && len(fileToTree) > 0 {
		if err := e.snapshots.RestoreFiles(ctx, absWorkdir, fileToTree); err != nil {
			return Session{}, 0, err
		}
		restoredCount = len(fileToTree)
		if e.Audit != nil {
			e.Audit.Write("ai.revert", map[string]any{"session": sessionID, "files": restoredCount})
		}
	}

	e.mu.Lock()
	s = e.sessions[sessionID]
	if s == nil {
		e.mu.Unlock()
		return Session{}, 0, fmt.Errorf("session not found: %s", sessionID)
	}
	if idx <= len(s.Messages) {
		s.Messages = append([]Message(nil), s.Messages[:idx]...)
	}
	s.LastInputToks = EstimateMessagesTokens(BuildActiveHistory(s.Messages))
	s.UpdatedAt = time.Now().UnixMilli()
	_ = e.persistSessionLocked(s)
	out := cloneSession(s)
	e.mu.Unlock()

	e.broadcast(StreamEvent{
		Type:      "session.reverted",
		SessionID: sessionID,
		MessageID: messageID,
	})
	return out, restoredCount, nil
}

func truncateShort(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}
