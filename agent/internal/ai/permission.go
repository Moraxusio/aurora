package ai

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"
)

// PermissionDecision is returned by the user when approving or denying a tool call.
type PermissionDecision struct {
	Allow  bool   `json:"allow"`
	Always bool   `json:"always,omitempty"` // remember for the remainder of the session
	Reason string `json:"reason,omitempty"`
}

// PermissionGate enforces agent-mode restrictions ("plan", "explore", "build"),
// user permission mode ("ask" vs "auto"), sensitive file rules, destructive bash
// scanning, and OpenCode's 3-strike doom-loop detector.
type PermissionGate struct {
	mu          sync.Mutex
	allowedKeys map[string]bool // sessionID + "\x00" + action + "\x00" + pattern
	pending     map[string]*pendingPermission
}

type pendingPermission struct {
	question PermissionQuestion
	ch       chan PermissionDecision
}

func NewPermissionGate() *PermissionGate {
	return &PermissionGate{
		allowedKeys: map[string]bool{},
		pending:     map[string]*pendingPermission{},
	}
}

func (g *PermissionGate) PendingForSession(sessionID string) *PermissionQuestion {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, p := range g.pending {
		if p.question.SessionID == sessionID {
			q := p.question
			return &q
		}
	}
	return nil
}

func (g *PermissionGate) Resolve(id string, dec PermissionDecision) bool {
	g.mu.Lock()
	p, ok := g.pending[id]
	if ok {
		delete(g.pending, id)
		if dec.Allow && dec.Always {
			key := p.question.SessionID + "\x00" + p.question.Action + "\x00" + savePattern(p.question.Action, p.question.Resource)
			g.allowedKeys[key] = true
		}
	}
	g.mu.Unlock()
	if !ok {
		return false
	}
	select {
	case p.ch <- dec:
	default:
	}
	return true
}

func (g *PermissionGate) CancelSession(sessionID string) {
	g.mu.Lock()
	var chans []chan PermissionDecision
	for id, p := range g.pending {
		if p.question.SessionID == sessionID {
			delete(g.pending, id)
			chans = append(chans, p.ch)
		}
	}
	g.mu.Unlock()
	for _, ch := range chans {
		select {
		case ch <- PermissionDecision{Allow: false, Reason: "cancelled"}:
		default:
		}
	}
}

func savePattern(action, resource string) string {
	if action == "shell" {
		fields := strings.Fields(resource)
		if len(fields) > 0 {
			return fields[0] + " *"
		}
	}
	return "*"
}

// Evaluate decides ("allow", "ask", "deny") and a human-readable reason.
func (g *PermissionGate) Evaluate(sessionID, agentMode, permMode, action, resource string) (string, string) {
	// Plan & Explore hard guardrails
	if agentMode == "plan" {
		if action == "write" || action == "edit" {
			return "deny", "Plan mode is read-only: switch to Build mode to edit or write files."
		}
		if action == "shell" && !isReadOnlyShellCommand(resource) {
			return "ask", "Plan mode requires confirmation for non-read-only shell commands."
		}
	}
	if agentMode == "explore" {
		if action == "write" || action == "edit" || action == "subagent" {
			return "deny", "Explore subagent is strictly read-only."
		}
		if action == "shell" && !isReadOnlyShellCommand(resource) {
			return "deny", "Explore subagent cannot run mutating shell commands."
		}
	}

	// Sensitive credential files (.env, private keys)
	if action == "read" || action == "edit" || action == "write" {
		if isSensitiveFile(resource) {
			if permMode == "auto" && action == "read" {
				// Even in auto mode, reading .env/private keys asks unless already approved.
			}
			if !g.isRemembered(sessionID, action, resource) {
				return "ask", "Accessing potential secret or environment credential file"
			}
		}
	}

	if action == "doom_loop" {
		return "ask", "Repeated identical tool call detected (3 times in a row)"
	}

	if permMode == "auto" {
		// Even in auto mode, guard clearly catastrophic system-wide commands unless explicitly approved.
		if action == "shell" && isHighRiskShellCommand(resource) && !g.isRemembered(sessionID, action, resource) {
			return "ask", "High-impact shell command requires confirmation"
		}
		return "allow", ""
	}

	// Default mode == "ask" (like OpenCode interactive default: reads/searches allowed, mutations & non-trivial shell ask)
	switch action {
	case "read", "glob", "grep", "todowrite", "subagent":
		return "allow", ""
	case "edit", "write":
		if g.isRemembered(sessionID, action, resource) {
			return "allow", ""
		}
		return "ask", "File modification requires approval"
	case "shell":
		if isReadOnlyShellCommand(resource) || g.isRemembered(sessionID, action, resource) {
			return "allow", ""
		}
		return "ask", "Shell command execution requires approval"
	default:
		return "allow", ""
	}
}

func (g *PermissionGate) isRemembered(sessionID, action, resource string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.allowedKeys[sessionID+"\x00"+action+"\x00*"] {
		return true
	}
	pat := savePattern(action, resource)
	return g.allowedKeys[sessionID+"\x00"+action+"\x00"+pat]
}

// Ask registers a pending permission question, emits it via emitFn, and blocks until resolved or ctx cancelled.
func (g *PermissionGate) Ask(ctx context.Context, q PermissionQuestion, emitFn func(PermissionQuestion)) error {
	if q.ID == "" {
		q.ID = NewID("perm")
	}
	ch := make(chan PermissionDecision, 1)
	g.mu.Lock()
	g.pending[q.ID] = &pendingPermission{question: q, ch: ch}
	g.mu.Unlock()

	if emitFn != nil {
		emitFn(q)
	}

	select {
	case <-ctx.Done():
		g.mu.Lock()
		delete(g.pending, q.ID)
		g.mu.Unlock()
		return ctx.Err()
	case dec := <-ch:
		if !dec.Allow {
			if dec.Reason != "" {
				return errors.New("Permission denied by user: " + dec.Reason)
			}
			return errors.New("Permission denied by user.")
		}
		return nil
	}
}

func isSensitiveFile(p string) bool {
	base := strings.ToLower(filepath.Base(p))
	if base == ".env.example" || base == ".env.sample" || base == ".env.template" {
		return false
	}
	if base == ".env" || strings.HasPrefix(base, ".env.") {
		return true
	}
	if base == "id_rsa" || base == "id_ed25519" || base == "id_ecdsa" || strings.HasSuffix(base, ".pem") || strings.HasSuffix(base, ".key") {
		return true
	}
	return false
}

var readOnlyCmds = map[string]bool{
	"pwd": true, "ls": true, "whoami": true, "uname": true, "date": true, "uptime": true,
	"df": true, "du": true, "free": true, "ps": true, "which": true, "type": true,
	"wc": true, "head": true, "tail": true, "cat": true, "stat": true, "file": true,
	"rg": true, "grep": true, "find": true, "echo": true, "true": true,
}

func isReadOnlyShellCommand(cmd string) bool {
	trimmed := strings.TrimSpace(cmd)
	if trimmed == "" {
		return true
	}
	// Reject redirections, subshells, backgrounding, or compound operators for automatic read-only classification.
	if strings.ContainsAny(trimmed, ">;`$&|\n") {
		return false
	}
	fields := strings.Fields(trimmed)
	if len(fields) == 0 {
		return true
	}
	prog := filepath.Base(fields[0])
	if prog == "git" && len(fields) >= 2 {
		switch fields[1] {
		case "status", "diff", "log", "show", "branch", "rev-parse", "ls-files", "remote":
			if len(fields) == 2 || (fields[1] != "branch" && fields[1] != "remote") {
				return true
			}
			if fields[1] == "branch" && (fields[2] == "-a" || fields[2] == "-r" || fields[2] == "--show-current" || fields[2] == "-v") {
				return true
			}
		}
		return false
	}
	if prog == "systemctl" && len(fields) >= 2 && (fields[1] == "status" || fields[1] == "list-units" || fields[1] == "is-active") {
		return true
	}
	if prog == "journalctl" {
		return true
	}
	if prog == "find" {
		for _, f := range fields[1:] {
			if f == "-delete" || f == "-exec" || f == "-execdir" || f == "-ok" {
				return false
			}
		}
		return true
	}
	return readOnlyCmds[prog]
}

func isHighRiskShellCommand(cmd string) bool {
	lower := " " + strings.ToLower(cmd) + " "
	highRisk := []string{
		" rm -rf /", " rm -fr /", " mkfs", " dd if=", " shutdown", " reboot", " poweroff",
		" init 0", " iptables -f", " ufw reset", " > /dev/sd", " chmod -r 777 /",
	}
	for _, pat := range highRisk {
		if strings.Contains(lower, pat) {
			return true
		}
	}
	return false
}
