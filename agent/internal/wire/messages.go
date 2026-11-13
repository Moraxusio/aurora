package wire

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Version is the protocol version. Peers refuse a different major version.
const Version = "3.0"

const (
	RoleClient  = "client"
	RoleAgent   = "agent"
	RoleUpdater = "updater" // an agent's dedicated update session to the relay
)

// Hello is the first frame on every TLS connection.
type Hello struct {
	Role    string     `json:"role"`
	Token   string     `json:"token"`
	Version string     `json:"version"`
	Client  string     `json:"client,omitempty"` // client software version
	Target  string     `json:"target,omitempty"` // client via relay: agent id to reach
	Agent   *AgentInfo `json:"agent,omitempty"`  // agent registering with a relay
}

// HelloReply answers a Hello. On success the connection switches to yamux.
type HelloReply struct {
	OK      bool        `json:"ok"`
	Error   string      `json:"error,omitempty"`
	Version string      `json:"version"`
	Server  *AgentInfo  `json:"server,omitempty"` // the agent serving this session
	Agents  []AgentInfo `json:"agents,omitempty"` // relay: every registered agent
}

// AgentInfo describes one server. Relays hand it to authenticated clients so
// they can configure the direct link to a new machine automatically.
type AgentInfo struct {
	Kind      string     `json:"kind,omitempty"`
	Platform  string     `json:"platform,omitempty"`
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Host      string     `json:"host"`
	OS        string     `json:"os"`
	Version   string     `json:"version"`
	Arch      string     `json:"arch,omitempty"`
	ExeSHA256 string     `json:"exe_sha256,omitempty"`
	Caps      []string   `json:"caps"`
	Direct    DirectInfo `json:"direct"`
	Online    bool       `json:"online,omitempty"`
	LastSeen  int64      `json:"last_seen,omitempty"`
}

// DirectInfo is everything a client needs to dial an agent without the relay.
type DirectInfo struct {
	Port       int      `json:"port"`
	QUIC       int      `json:"quic,omitempty"` // UDP port of the QUIC listener (same hosts as Addrs)
	Addrs      []string `json:"addrs"`
	CertSHA256 string   `json:"cert_sha256"`
	Token      string   `json:"token,omitempty"`
}

// Request opens every stream.
type Request struct {
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args,omitempty"`
}

// Error codes map to HTTP statuses in the client.
const (
	CodeBadRequest  = "bad_request"
	CodeNotFound    = "not_found"
	CodeConflict    = "conflict"
	CodeForbidden   = "forbidden"
	CodeUnsupported = "unsupported"
	CodeUnavailable = "unavailable"
	CodeInternal    = "internal"
)

// Response ends unary calls and starts streaming ones.
type Response struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
	Code   string          `json:"code,omitempty"`
}

// OpError is a typed failure carried across the wire.
type OpError struct {
	Code string
	Msg  string
}

func (e *OpError) Error() string { return e.Msg }

func Errf(code, format string, a ...any) error {
	return &OpError{Code: code, Msg: fmt.Sprintf(format, a...)}
}

// CodeOf returns the wire code for err (internal when untyped).
func CodeOf(err error) string {
	var oe *OpError
	if errors.As(err, &oe) {
		return oe.Code
	}
	return CodeInternal
}

func OKResponse(v any) Response {
	b, err := json.Marshal(v)
	if err != nil {
		return ErrResponse(err)
	}
	return Response{OK: true, Result: b}
}

func ErrResponse(err error) Response {
	msg := err.Error()
	if len(msg) > 400 {
		msg = msg[:400]
	}
	return Response{OK: false, Error: msg, Code: CodeOf(err)}
}

// Err converts a failed Response back into an error.
func (r Response) Err() error {
	if r.OK {
		return nil
	}
	code := r.Code
	if code == "" {
		code = CodeInternal
	}
	return &OpError{Code: code, Msg: r.Error}
}

// TerminalControl frames travel as 'J' inside a terminal stream.
type TerminalControl struct {
	Type string `json:"type"` // resize | close | ping | pong | exit | detached
	Cols int    `json:"cols,omitempty"`
	Rows int    `json:"rows,omitempty"`
	Code int    `json:"code,omitempty"`
}
