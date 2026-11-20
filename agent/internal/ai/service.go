//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"aurora3/internal/service"
	"aurora3/internal/wire"
)

// Service adapts Env to service.Service (D-41, D-45, D-104).
func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ *Env }

func (svc) ID() string { return ServiceID }

func (svc) Dependencies() []service.Dependency {
	return []service.Dependency{
		{Name: "git", Purpose: "shadow-git tree snapshots & 1-click revert", Required: false},
	}
}

func (s svc) Switched(on bool) {
	if !on {
		s.StopAll()
	}
}

func (s svc) Operations() []service.Operation {
	return []service.Operation{
		{Name: "ai.sessions", Handle: s.opSessions},
		{Name: "ai.get", Handle: s.opGet},
		{Name: "ai.history", Stream: s.opHistory},
		{Name: "ai.delete", Handle: s.opDelete},
		{Name: "ai.run", Handle: s.opRun},
		{Name: "ai.propose", Stream: s.opPropose},
		{Name: "ai.extensions", Handle: s.opExtensions},
		{Name: "ai.mcp.probe", Handle: s.opMCPProbe},
		{Name: "ai.snapshots.prune", Handle: s.opPruneSnapshots},
		{Name: "ai.snapshots.inspect", Handle: s.opInspectSnapshots},
		{Name: "ai.run.options", Handle: s.opRunOptions},
		{Name: "ai.stop", Handle: s.opStop},
		{Name: "ai.approve", Handle: s.opApprove},
		{Name: "ai.inbox", Handle: s.opInbox},
		{Name: "ai.permissions", Handle: s.opPermissions},
		{Name: "ai.permissions.full_access", Handle: func(_ context.Context, _ json.RawMessage) (any, error) {
			return map[string]any{"mode": "full_access", "live": true}, nil
		}},
		{Name: "ai.question", Handle: s.opQuestion},
		{Name: "ai.capabilities", Handle: func(_ context.Context, _ json.RawMessage) (any, error) {
			return map[string]any{"version": 1, "capabilities": resolvedCapabilities(ProviderConfig{}), "tool_media": true, "durable_steps": true}, nil
		}},
		{Name: "ai.revert", Handle: s.opRevert},
		{Name: "ai.revert.preview", Handle: s.opRevertPreview},
		{Name: "ai.compact", Handle: s.opCompact},
		{Name: "ai.models", Handle: s.opModels},
		{Name: "ai.network", Handle: s.opNetwork},
		{Name: "ai.auth.begin", Handle: s.opAuthBegin},
		{Name: "ai.auth.poll", Handle: s.opAuthPoll},
		{Name: "ai.auth.refresh", Handle: s.opAuthRefresh},
		{Name: "ai.update", Handle: s.opUpdate},
		{Name: "ai.search", Handle: s.opSearch},
		{Name: "ai.export", Handle: s.opExport},
		{Name: "ai.stream", Stream: s.opStream},
		{Name: "ai.attach.upload", Stream: s.opAttachmentUpload},
		{Name: "ai.attach.download", Stream: s.opAttachmentDownload},
	}
}

func (s svc) opInbox(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		SessionID string `json:"session_id"`
		ID        string `json:"id"`
		Action    string `json:"action"` // cancel | steer | queue; empty lists
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	s.init()
	s.mu.Lock()
	session := s.sessionLocked(in.SessionID)
	if session == nil {
		s.mu.Unlock()
		return nil, wire.Errf(wire.CodeNotFound, "会话不存在")
	}
	if in.Action != "" {
		if s.maintenance[in.SessionID] != nil {
			s.mu.Unlock()
			return nil, wire.Errf(wire.CodeConflict, "会话正在维护")
		}
		if in.Action != "cancel" && in.Action != "steer" && in.Action != "queue" {
			s.mu.Unlock()
			return nil, wire.Errf(wire.CodeBadRequest, "不支持的投递操作")
		}
		index := -1
		for i, item := range session.Inbox {
			if item.ID == in.ID {
				index = i
				break
			}
		}
		if index < 0 {
			s.mu.Unlock()
			return nil, wire.Errf(wire.CodeNotFound, "输入已投递或已移除")
		}
		before := append([]InboxItem(nil), session.Inbox...)
		item := session.Inbox[index]
		if in.Action == "steer" && item.Options.changed() {
			s.mu.Unlock()
			return nil, wire.Errf(wire.CodeBadRequest, "这条消息有独立运行设置，请保持排队发送；补充指令会沿用当前任务预算")
		}
		if in.Action != "cancel" && !s.inboxActiveLocked(in.SessionID, in.ID) {
			s.mu.Unlock()
			return nil, wire.Errf(wire.CodeBadRequest, "这条输入已保留，请等待当前任务停止后使用当前选择重新发送")
		}
		if in.Action == "cancel" {
			session.Inbox = append(session.Inbox[:index], session.Inbox[index+1:]...)
		} else {
			item.Delivery = in.Action
			session.Inbox[index] = item
		}
		if err := s.persistSessionLocked(session); err != nil {
			session.Inbox = before
			s.mu.Unlock()
			return nil, wire.Errf(wire.CodeInternal, "%v", err)
		}
		if run := s.running[in.SessionID]; run != nil {
			remove := func(items []InboxItem) []InboxItem {
				for i, v := range items {
					if v.ID == in.ID {
						return append(items[:i], items[i+1:]...)
					}
				}
				return items
			}
			run.inbox = remove(run.inbox)
			run.queued = remove(run.queued)
			if in.Action == "steer" {
				run.inbox = append(run.inbox, item)
			}
			if in.Action == "queue" {
				run.queued = append(run.queued, item)
			}
		}
	}
	pending := s.inboxSnapshotLocked(session)
	s.mu.Unlock()
	if in.Action != "" {
		s.broadcast(StreamEvent{Type: "inbox.updated", SessionID: in.SessionID, Inbox: pending})
	}
	return map[string]any{"items": pending}, nil
}

func (s svc) opPermissions(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		SessionID string `json:"session_id"`
		Action    string `json:"action"`
		Resource  string `json:"resource"`
		Revoke    bool   `json:"revoke"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	s.init()
	if _, _, _, err := s.GetSession(in.SessionID); err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "%v", err)
	}
	return map[string]any{"grants": s.perms.SessionGrants(in.SessionID, in.Action, in.Resource, in.Revoke)}, nil
}

func (s svc) opUpdate(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		ID              string            `json:"id"`
		Title           *string           `json:"title"`
		Pinned          *bool             `json:"pinned"`
		PermissionMode  *string           `json:"permission_mode"`
		PermissionRules *[]PermissionRule `json:"permission_rules"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.ID) == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少会话 ID")
	}
	resolved := []string{}
	if in.PermissionMode != nil || in.PermissionRules != nil {
		ids, err := s.UpdateSessionPermission(in.ID, in.PermissionMode, in.PermissionRules)
		if err != nil {
			return nil, wire.Errf(wire.CodeBadRequest, "%v", err)
		}
		resolved = ids
	}
	if in.Title != nil || in.Pinned != nil {
		sum, err := s.UpdateSessionMeta(in.ID, in.Title, in.Pinned)
		if err != nil {
			return nil, wire.Errf(wire.CodeNotFound, "%v", err)
		}
		return map[string]any{"session": sum, "resolved": len(resolved), "resolved_ids": resolved}, nil
	}
	return map[string]any{"updated": true, "resolved": len(resolved), "resolved_ids": resolved}, nil
}

func (s svc) opSearch(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	hits, err := s.searchSessionsContext(ctx, in.Query, in.Limit)
	return map[string]any{"hits": hits}, err
}

func (s svc) opExport(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	name, md, err := s.ExportMarkdown(in.ID)
	if err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "%v", err)
	}
	return map[string]any{"name": name, "markdown": md}, nil
}

func decodeArgs(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

func (s svc) opSessions(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		IncludeChildren bool `json:"include_children"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	return map[string]any{
		"sessions": s.ListSessions(in.IncludeChildren),
	}, nil
}

func (s svc) opGet(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.ID) == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少会话 ID")
	}
	sess, running, pending, err := s.GetSession(in.ID)
	if err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "%v", err)
	}
	permissions := []PermissionQuestion{}
	seen := map[string]bool{}
	if pending != nil {
		permissions = append(permissions, *pending)
		seen[pending.ID] = true
	}
	for _, activity := range s.activitiesFor(in.ID) {
		if q := s.perms.PendingForSession(activity.SessionID); q != nil && !seen[q.ID] {
			permissions = append(permissions, *q)
			seen[q.ID] = true
			if pending == nil {
				pending = q
			}
		}
	}
	return map[string]any{
		"session":             sess,
		"running":             running,
		"pending_permission":  pending,
		"pending_permissions": permissions,
		"activities":          s.activitiesFor(in.ID),
	}, nil
}

func (s svc) opDelete(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.ID) == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少会话 ID")
	}
	if err := s.DeleteSession(in.ID); err != nil {
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	return map[string]any{"deleted": true}, nil
}

func (s svc) opRun(_ context.Context, raw json.RawMessage) (any, error) {
	var in RunInput
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	sum, err := s.StartRun(in)
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	return map[string]any{"session": sum}, nil
}

func (s svc) opStop(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	stopped := s.StopSession(in.ID)
	return map[string]any{"stopped": stopped}, nil
}

func (s svc) opApprove(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		ID         string `json:"id"`
		Allow      bool   `json:"allow"`
		Always     bool   `json:"always"`
		TTLSeconds int64  `json:"ttl_seconds"`
		Reason     string `json:"reason"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.ID) == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少权限请求 ID")
	}
	ok := s.perms.Resolve(in.ID, PermissionDecision{
		Allow:      in.Allow,
		Always:     in.Always,
		TTLSeconds: in.TTLSeconds,
		Reason:     in.Reason,
	})
	return map[string]any{"resolved": ok}, nil
}

func (s svc) opRevert(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		SessionID string        `json:"session_id"`
		MessageID string        `json:"message_id"`
		Files     *bool         `json:"files"`
		Review    *revertReview `json:"review"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if in.SessionID == "" || in.MessageID == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少 session_id 或 message_id")
	}
	restoreFiles := true
	if in.Files != nil {
		restoreFiles = *in.Files
	}
	if restoreFiles && (in.Review == nil || len(in.Review.Paths) == 0) {
		return nil, wire.Errf(wire.CodeBadRequest, "请先预览并明确选择要回退的文件；旧客户端请升级")
	}
	sess, count, err := s.revertSession(ctx, in.SessionID, in.MessageID, restoreFiles, in.Review)
	if err != nil {
		if errors.Is(err, errRevertReview) {
			return nil, wire.Errf(wire.CodeConflict, "%v", err)
		}
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	if in.Review != nil {
		return map[string]any{"session_id": sess.ID, "restored_files": count}, nil
	}
	return map[string]any{
		"session":        sess,
		"restored_files": count,
	}, nil
}

func (s svc) opCompact(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		SessionID string         `json:"session_id"`
		Provider  ProviderConfig `json:"provider"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	if in.SessionID == "" {
		return nil, wire.Errf(wire.CodeBadRequest, "缺少 session_id")
	}
	msg, err := s.CompactSession(ctx, in.SessionID, in.Provider)
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "%v", err)
	}
	return map[string]any{"message": msg}, nil
}

func (s svc) opModels(ctx context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		Provider ProviderConfig `json:"provider"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	models, err := FetchModels(ctx, in.Provider, s.proxyFor(in.Provider))
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "获取模型列表失败：%v", err)
	}
	return map[string]any{"models": models}, nil
}

// opStream pushes real-time StreamEvents over aurora_wire JSON frames.
// Optional args {"session_id": "..."} filters to a single session; empty streams all sessions.
func (s svc) opStream(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var in struct {
		SessionID string `json:"session_id"`
	}
	_ = json.Unmarshal(raw, &in)

	var filterMu sync.RWMutex
	filterSession := in.SessionID

	var wmu sync.Mutex
	send := func(v any) error {
		wmu.Lock()
		defer wmu.Unlock()
		_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
		return wire.WriteJSON(st, v)
	}
	sub := s.subscribe()
	defer s.unsubscribe(sub)
	if err := send(wire.Response{OK: true}); err != nil {
		return nil
	}

	cctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Read client control frames (e.g. {"type":"filter","session_id":"..."} or EOF when client closes stream)
	go func() {
		defer cancel()
		for {
			typ, p, err := wire.ReadFrame(st)
			if err != nil {
				return
			}
			if typ != wire.TypeJSON {
				continue
			}
			var ctl struct {
				Type      string `json:"type"`
				SessionID string `json:"session_id"`
			}
			if json.Unmarshal(p, &ctl) == nil && ctl.Type == "filter" {
				filterMu.Lock()
				filterSession = ctl.SessionID
				filterMu.Unlock()
			}
		}
	}()

	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()

	for {
		select {
		case <-cctx.Done():
			return nil
		case <-keepalive.C:
			if send(StreamEvent{Type: "ping"}) != nil {
				return nil
			}
		case ev := <-sub:
			filterMu.RLock()
			want := filterSession
			filterMu.RUnlock()
			if want != "" && ev.SessionID != "" && ev.SessionID != want && ev.RootSessionID != want {
				continue
			}
			if err := send(ev); err != nil {
				if err != wire.ErrFrameTooLarge || send(StreamEvent{Type: "sync.required", SessionID: ev.SessionID, RootSessionID: ev.RootSessionID}) != nil {
					return nil
				}
			}
		}
	}
}
