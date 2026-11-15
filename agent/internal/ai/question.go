//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"aurora3/internal/wire"
)

type QuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}
type QuestionItem struct {
	Question string           `json:"question"`
	Header   string           `json:"header,omitempty"`
	Options  []QuestionOption `json:"options,omitempty"`
	Multiple bool             `json:"multiple,omitempty"`
}
type UserQuestion struct {
	ID        string         `json:"id"`
	SessionID string         `json:"session_id"`
	Questions []QuestionItem `json:"questions"`
}
type questionAnswer struct {
	Answers [][]string
	Cancel  bool
}
type pendingQuestion struct {
	value    UserQuestion
	answer   chan questionAnswer
	answered bool
}

var questionToolDef = ToolDef{
	Name:        "question",
	Description: "Ask the user focused questions when a decision or missing requirement blocks progress. Supports choices, multiple selection and a custom answer. The run waits for the answer; do not use this for routine status updates or permissions (tools request permission separately).",
	Parameters: map[string]any{
		"type": "object",
		"properties": map[string]any{
			"questions": map[string]any{"type": "array", "minItems": 1, "maxItems": 5, "items": map[string]any{
				"type": "object", "properties": map[string]any{
					"question": map[string]any{"type": "string"},
					"header":   map[string]any{"type": "string"},
					"multiple": map[string]any{"type": "boolean"},
					"options": map[string]any{"type": "array", "maxItems": 8, "items": map[string]any{
						"type": "object", "properties": map[string]any{
							"label":       map[string]any{"type": "string"},
							"description": map[string]any{"type": "string"},
						}, "required": []string{"label"},
					}},
				}, "required": []string{"question"},
			}},
		}, "required": []string{"questions"},
	},
}

func execQuestionTool(ctx context.Context, tc toolContext, raw json.RawMessage) ToolExecResult {
	var in struct {
		Questions []QuestionItem `json:"questions"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	if len(in.Questions) < 1 || len(in.Questions) > 5 {
		return ToolExecResult{Output: "Ask between 1 and 5 questions.", IsError: true}
	}
	for _, q := range in.Questions {
		if strings.TrimSpace(q.Question) == "" || len(q.Question) > 4000 || len(q.Header) > 120 || len(q.Options) > 8 {
			return ToolExecResult{Output: "Invalid question: use a nonempty question up to 4000 bytes and at most 8 choices.", IsError: true}
		}
		labels := map[string]bool{}
		for _, option := range q.Options {
			if strings.TrimSpace(option.Label) == "" || len(option.Label) > 200 || len(option.Description) > 1000 || labels[option.Label] {
				return ToolExecResult{Output: "Question choices need unique nonempty labels up to 200 bytes.", IsError: true}
			}
			labels[option.Label] = true
		}
	}
	if err := ctx.Err(); err != nil {
		return ToolExecResult{Output: err.Error(), IsError: true}
	}
	e := tc.env
	e.init()
	pending := &pendingQuestion{value: UserQuestion{ID: NewID("que"), SessionID: tc.session.ID, Questions: in.Questions}, answer: make(chan questionAnswer, 1)}
	e.mu.Lock()
	if e.questions[tc.session.ID] != nil {
		e.mu.Unlock()
		return ToolExecResult{Output: "A user question is already pending.", IsError: true}
	}
	e.questions[tc.session.ID] = pending
	e.broadcastLocked(StreamEvent{Type: "question.ask", SessionID: tc.session.ID, ToolCallID: tc.callID, Question: &pending.value})
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		if e.questions[tc.session.ID] == pending {
			delete(e.questions, tc.session.ID)
		}
		e.broadcastLocked(StreamEvent{Type: "question.done", SessionID: tc.session.ID, ToolCallID: tc.callID})
		e.mu.Unlock()
	}()
	select {
	case <-ctx.Done():
		return ToolExecResult{Output: "Question cancelled because the run stopped. No user answer was received.", IsError: true}
	case answer := <-pending.answer:
		if answer.Cancel {
			return ToolExecResult{Output: "The user skipped this question. Do not assume an answer; continue only with the information available."}
		}
		out, _ := json.Marshal(map[string]any{"questions": in.Questions, "answers": answer.Answers})
		return ToolExecResult{Output: string(out)}
	}
}

func (s svc) opQuestion(_ context.Context, raw json.RawMessage) (any, error) {
	var in struct {
		SessionID string     `json:"session_id"`
		ID        string     `json:"id"`
		Answers   [][]string `json:"answers"`
		Cancel    bool       `json:"cancel"`
	}
	if err := decodeArgs(raw, &in); err != nil {
		return nil, err
	}
	s.init()
	s.mu.Lock()
	defer s.mu.Unlock()
	pending := s.questions[in.SessionID]
	if in.ID == "" {
		if pending == nil || pending.answered {
			return map[string]any{"question": nil}, nil
		}
		return map[string]any{"question": pending.value}, nil
	}
	if pending == nil || pending.value.ID != in.ID {
		return nil, wire.Errf(wire.CodeNotFound, "问题已结束或不属于当前会话")
	}
	if pending.answered {
		return map[string]any{"accepted": true}, nil
	}
	if !in.Cancel {
		if len(in.Answers) != len(pending.value.Questions) {
			return nil, wire.Errf(wire.CodeBadRequest, "请回答每个问题")
		}
		for i, values := range in.Answers {
			if len(values) == 0 || len(values) > 9 || (!pending.value.Questions[i].Multiple && len(values) != 1) {
				return nil, wire.Errf(wire.CodeBadRequest, "问题 %d 的答案数量无效", i+1)
			}
			for _, value := range values {
				if strings.TrimSpace(value) == "" || len(value) > 4096 {
					return nil, wire.Errf(wire.CodeBadRequest, "%s", fmt.Sprintf("问题 %d 的答案不能为空且最多 4096 字节", i+1))
				}
			}
		}
	}
	pending.answered = true
	pending.answer <- questionAnswer{Answers: in.Answers, Cancel: in.Cancel}
	return map[string]any{"accepted": true}, nil
}
