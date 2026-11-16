//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"runtime"
	"strings"
)

func (s svc) opPruneSnapshots(ctx context.Context, raw json.RawMessage) (any, error) {
	s.init()
	var in struct{ Root, Workdir string }
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	_, _, work, err := s.resolveWorkspace(in.Root, in.Workdir)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	s.mu.Lock()
	if len(s.running) > 0 || len(s.maintenance) > 0 {
		s.mu.Unlock()
		return nil, errors.New("请等待 AI 运行及维护结束后清理快照")
	}
	if err := s.validateSessionReferencesLocked(); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	s.maintenance["snapshots:gc"] = cancel
	keep := map[string]bool{}
	for _, session := range s.sessions {
		_, _, path, err := s.resolveWorkspace(session.Root, session.Workdir)
		same := err == nil && filepath.Clean(path) == filepath.Clean(work)
		if runtime.GOOS == "windows" {
			same = err == nil && strings.EqualFold(filepath.Clean(path), filepath.Clean(work))
		}
		if !same {
			continue
		}
		if r := s.records[session.ID]; r != nil {
			for _, tree := range r.index.Trees {
				keep[tree] = true
			}
		}
		for _, message := range session.Messages {
			if snap := message.Snapshot; snap != nil {
				if snap.Start != "" {
					keep[snap.Start] = true
				}
				if snap.End != "" {
					keep[snap.End] = true
				}
			}
		}
	}
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(s.maintenance, "snapshots:gc"); s.mu.Unlock() }()
	return s.snapshots.Prune(ctx, work, keep)
}
