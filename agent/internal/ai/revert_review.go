//go:build linux || windows

package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"

	"aurora3/internal/filetxn"
	"aurora3/internal/wire"
)

var errRevertReview = errors.New("回退目标、会话或选择已变化，请重新预览")

type revertReview struct {
	Revision string   `json:"revision"`
	Paths    []string `json:"paths"`
}

type revertPreview struct {
	Revision string   `json:"revision"`
	Paths    []string `json:"paths"`
	Overflow bool     `json:"overflow,omitempty"`
	pathSet  map[string]bool
}

// Shadow trees record a time window, not authorship. Preview never labels
// changes as AI-owned and does not select any file on the user's behalf.
func makeRevertPreview(s *Session, index int) revertPreview {
	hash := sha256.New()
	emitter := json.NewEncoder(hash)
	_ = emitter.Encode([]string{s.ID, s.Root, s.Workdir})
	out := revertPreview{Paths: []string{}, pathSet: map[string]bool{}}
	for _, msg := range s.Messages[index:] {
		_ = emitter.Encode(msg.ID)
		if snap := msg.Snapshot; snap != nil {
			_ = emitter.Encode([]string{snap.Start, snap.End, snap.Warning})
			for _, f := range snap.Files {
				_ = emitter.Encode(f.File)
				if snap.Start != "" && snap.End != "" && !out.pathSet[f.File] {
					if len(out.Paths) == filetxn.MaxChanges-2 {
						out.Overflow = true
						continue
					}
					out.pathSet[f.File] = true
					out.Paths = append(out.Paths, f.File)
				}
			}
		}
	}
	out.Revision = hex.EncodeToString(hash.Sum(nil))
	// A unary preview must stay comfortably under the wire frame limit,
	// including JSON escaping of path characters.
	if data, _ := json.Marshal(out.Paths); len(data) > 256<<10 {
		out.Overflow = true
		out.Paths = nil
		out.pathSet = nil
	}
	sort.Strings(out.Paths)
	return out
}

func (s svc) opRevertPreview(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		SessionID string `json:"session_id"`
		MessageID string `json:"message_id"`
	}
	if err := decodeArgs(raw, &a); err != nil {
		return nil, err
	}
	s.init()
	s.mu.Lock()
	defer s.mu.Unlock()
	session := s.sessionLocked(a.SessionID)
	if session == nil {
		return nil, wire.Errf(wire.CodeNotFound, "会话不存在")
	}
	if s.running[a.SessionID] != nil || s.maintenance[a.SessionID] != nil {
		return nil, wire.Errf(wire.CodeConflict, "%v", errRevertReview)
	}
	for i, msg := range session.Messages {
		if msg.ID == a.MessageID {
			return makeRevertPreview(session, i), nil
		}
	}
	return nil, wire.Errf(wire.CodeNotFound, "消息不存在")
}
