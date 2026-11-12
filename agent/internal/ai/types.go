// Package ai implements Aurora 3's built-in LLM coding & server agent service
// ("ai"). Its wire protocols, request headers, system prompts, tool schemas,
// 3-tier exact edit engine, tool-output truncation, shadow-git snapshots, and
// context compaction are ported from OpenCode (https://github.com/anomalyco/opencode,
// MIT License; see THIRD_PARTY_OPENCODE_LICENSE) for first-class compatibility
// with OpenCode-optimized LLM API gateways.
package ai

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"
)

const ServiceID = "ai"

// NewID generates an OpenCode-style prefixed identifier (e.g. "ses_...", "msg_...").
func NewID(prefix string) string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	ms := uint64(time.Now().UnixMilli())
	b[0] = byte(ms >> 40)
	b[1] = byte(ms >> 32)
	b[2] = byte(ms >> 24)
	b[3] = byte(ms >> 16)
	b[4] = byte(ms >> 8)
	b[5] = byte(ms)
	return fmt.Sprintf("%s_%s", prefix, hex.EncodeToString(b[:]))
}

// ProviderConfig carries the model endpoint and credentials for a run.
// The client keeps API keys encrypted in its local profile (D-72) and sends
// them per call over the pinned TLS link; the agent never writes APIKey to disk
// or logs.
type ProviderConfig struct {
	ID              string            `json:"id,omitempty"`
	Name            string            `json:"name,omitempty"`
	Protocol        string            `json:"protocol"` // "openai-chat" | "anthropic-messages" | "openai-responses"
	BaseURL         string            `json:"base_url"`
	APIKey          string            `json:"api_key,omitempty"`
	AuthMode        string            `json:"auth_mode,omitempty"` // "bearer" | "x-api-key" | "" (auto)
	Model           string            `json:"model"`
	ModelName       string            `json:"model_name,omitempty"`
	ContextWindow   int               `json:"context_window,omitempty"`
	MaxOutputTokens int               `json:"max_tokens,omitempty"`
	ReasoningEffort string            `json:"reasoning_effort,omitempty"` // "low" | "medium" | "high"
	Headers         map[string]string `json:"headers,omitempty"`
	UseProxy        bool              `json:"use_proxy"`
}

// Usage follows OpenCode's inclusive + breakdown token contract.
type Usage struct {
	InputTokens          int     `json:"input_tokens,omitempty"`
	OutputTokens         int     `json:"output_tokens,omitempty"`
	NonCachedInputTokens int     `json:"non_cached_input_tokens,omitempty"`
	CacheReadTokens      int     `json:"cache_read_tokens,omitempty"`
	CacheWriteTokens     int     `json:"cache_write_tokens,omitempty"`
	ReasoningTokens      int     `json:"reasoning_tokens,omitempty"`
	TotalTokens          int     `json:"total_tokens,omitempty"`
	Cost                 float64 `json:"cost,omitempty"`
}

func (u *Usage) Add(o Usage) {
	u.InputTokens += o.InputTokens
	u.OutputTokens += o.OutputTokens
	u.NonCachedInputTokens += o.NonCachedInputTokens
	u.CacheReadTokens += o.CacheReadTokens
	u.CacheWriteTokens += o.CacheWriteTokens
	u.ReasoningTokens += o.ReasoningTokens
	u.TotalTokens += o.TotalTokens
	u.Cost += o.Cost
}

type TodoItem struct {
	ID       string `json:"id"`
	Content  string `json:"content"`
	Status   string `json:"status"`   // "pending" | "in_progress" | "completed" | "cancelled"
	Priority string `json:"priority"` // "high" | "medium" | "low"
}

type FileDiff struct {
	File      string `json:"file"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
	Status    string `json:"status,omitempty"` // "added" | "modified" | "deleted"
	Patch     string `json:"patch,omitempty"`
}

type StepSnapshot struct {
	Start string     `json:"start,omitempty"`
	End   string     `json:"end,omitempty"`
	Files []FileDiff `json:"files,omitempty"`
}

// Part is one content block inside a Message.
type Part struct {
	Type string `json:"type"` // "text" | "reasoning" | "tool-call" | "tool-result" | "compaction"
	ID   string `json:"id,omitempty"`

	// Text / Reasoning / Compaction
	Text      string `json:"text,omitempty"`
	Signature string `json:"signature,omitempty"` // Anthropic thinking signature / OpenAI encrypted_content
	Redacted  string `json:"redacted,omitempty"`  // Anthropic redacted_thinking data

	// Tool call & result
	ToolName   string          `json:"name,omitempty"`
	ToolCallID string          `json:"tool_call_id,omitempty"`
	Input      json.RawMessage `json:"input,omitempty"`
	Output     string          `json:"output,omitempty"`
	IsError    bool            `json:"is_error,omitempty"`
	Metadata   map[string]any  `json:"metadata,omitempty"`

	// Provider-specific replay metadata (e.g. reasoningField, itemId)
	ProviderMeta map[string]any `json:"provider_meta,omitempty"`
}

type Message struct {
	ID        string        `json:"id"`
	SessionID string        `json:"session_id"`
	Role      string        `json:"role"` // "user" | "assistant" | "tool" | "compaction"
	Agent     string        `json:"agent,omitempty"`
	Model     string        `json:"model,omitempty"`
	Parts     []Part        `json:"parts"`
	Finish    string        `json:"finish,omitempty"` // "stop" | "tool-calls" | "length" | "aborted" | "error"
	Error     string        `json:"error,omitempty"`
	Usage     *Usage        `json:"usage,omitempty"`
	Snapshot  *StepSnapshot `json:"snapshot,omitempty"`
	KeepID    string        `json:"keep_id,omitempty"` // For compaction messages: first message ID kept verbatim
	CreatedAt int64         `json:"created_at"`
}

type ContextAttachment struct {
	Kind    string `json:"kind"` // "file" | "selection" | "git_diff" | "terminal" | "note"
	Label   string `json:"label"`
	Path    string `json:"path,omitempty"`
	Content string `json:"content"`
}

type InboxItem struct {
	ID          string              `json:"id"`
	Text        string              `json:"text"`
	Agent       string              `json:"agent,omitempty"` // "build" | "plan"
	Delivery    string              `json:"delivery"`        // "steer" | "queue"
	Attachments []ContextAttachment `json:"attachments,omitempty"`
	CreatedAt   int64               `json:"created_at"`
}

type Session struct {
	ID             string     `json:"id"`
	ParentID       string     `json:"parent_id,omitempty"`
	Title          string     `json:"title"`
	Root           string     `json:"root"`                    // Aurora root ID (e.g. "home")
	Workdir        string     `json:"workdir"`                 // Root-relative path (e.g. "/project")
	Agent          string     `json:"agent"`                   // "build" | "plan" | "explore" | "general"
	PermissionMode string     `json:"permission_mode,omitempty"` // "ask" | "auto"
	Model          string     `json:"model,omitempty"`
	Protocol       string     `json:"protocol,omitempty"`
	Todos          []TodoItem `json:"todos,omitempty"`
	TotalUsage     Usage      `json:"total_usage"`
	LastInputToks  int        `json:"last_input_tokens,omitempty"`
	Messages       []Message  `json:"messages"`
	CreatedAt      int64      `json:"created_at"`
	UpdatedAt      int64      `json:"updated_at"`
}

// SessionSummary is the lightweight metadata returned by ai.sessions.
type SessionSummary struct {
	ID                string                `json:"id"`
	ParentID          string                `json:"parent_id,omitempty"`
	Title             string                `json:"title"`
	Root              string                `json:"root"`
	Workdir           string                `json:"workdir"`
	Agent             string                `json:"agent"`
	Model             string                `json:"model,omitempty"`
	Running           bool                  `json:"running"`
	PendingPermission *PermissionQuestion   `json:"pending_permission,omitempty"`
	MessageCount      int                   `json:"message_count"`
	UpdatedAt         int64                 `json:"updated_at"`
}

// StreamEvent is pushed to subscribed clients over ai.stream.
type StreamEvent struct {
	Type       string              `json:"type"`
	SessionID  string              `json:"session_id"`
	MessageID  string              `json:"message_id,omitempty"`
	PartID     string              `json:"part_id,omitempty"`
	ToolCallID string              `json:"tool_call_id,omitempty"`
	ToolName   string              `json:"tool_name,omitempty"`
	Delta      string              `json:"delta,omitempty"`
	Title      string              `json:"title,omitempty"`
	Status     string              `json:"status,omitempty"`
	Error      string              `json:"error,omitempty"`
	Message    *Message            `json:"message,omitempty"`
	Input      json.RawMessage     `json:"input,omitempty"`
	Output     string              `json:"output,omitempty"`
	IsError    bool                `json:"is_error,omitempty"`
	Metadata   map[string]any      `json:"metadata,omitempty"`
	Permission *PermissionQuestion `json:"permission,omitempty"`
	Todos      []TodoItem          `json:"todos,omitempty"`
	Diffs      []FileDiff          `json:"diffs,omitempty"`
	Usage      *Usage              `json:"usage,omitempty"`
}

type PermissionQuestion struct {
	ID        string         `json:"id"`
	SessionID string         `json:"session_id"`
	MessageID string         `json:"message_id"`
	CallID    string         `json:"call_id"`
	Tool      string         `json:"tool"`
	Action    string         `json:"action"`
	Resource  string         `json:"resource"`
	Reason    string         `json:"reason,omitempty"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}
