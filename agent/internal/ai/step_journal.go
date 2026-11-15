//go:build linux || windows

package ai

import "time"

// A tool call must be durable before it can change external state. Results are
// checkpointed individually so a restart can distinguish known from unknown
// outcomes without replaying side effects.
func putStepMessage(s *Session, message Message) {
	for i := range s.Messages {
		if s.Messages[i].ID == message.ID {
			s.Messages[i] = message
			return
		}
	}
	s.Messages = append(s.Messages, message)
}

func (e *Env) checkpointStep(message Message) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := e.sessions[message.SessionID]
	if s == nil {
		return nil
	}
	putStepMessage(s, message)
	s.UpdatedAt = time.Now().UnixMilli()
	return e.persistSessionLocked(s)
}

func recoverInterruptedTools(s *Session) {
	for i, m := range s.Messages {
		if m.Role != "assistant" {
			continue
		}
		// IDs from older turns can be reused by gateways. Only this batch's
		// results (inline or legacy following tool messages) resolve its calls.
		results := map[string]bool{}
		record := func(parts []Part) {
			for _, p := range parts {
				if p.Type == "tool-result" {
					results[p.ToolCallID] = true
				}
			}
		}
		record(m.Parts)
		for j := i + 1; j < len(s.Messages) && s.Messages[j].Role == "tool"; j++ {
			record(s.Messages[j].Parts)
		}
		var missing []Part
		for _, p := range m.Parts {
			if p.Type == "tool-call" && !results[p.ToolCallID] {
				missing = append(missing, Part{Type: "tool-result", ID: NewID("prt"),
					ToolName: p.ToolName, ToolCallID: p.ToolCallID, IsError: true,
					Output: "Execution was interrupted before a durable result was recorded. The outcome is unknown; inspect the actual state before deciding whether to retry. This call was NOT automatically re-executed."})
			}
		}
		if len(missing) > 0 || m.Finish == "tool-running" {
			m.Parts = append(append([]Part(nil), m.Parts...), missing...)
			m.Finish = "aborted"
			s.Messages[i] = m
		}
	}
}
