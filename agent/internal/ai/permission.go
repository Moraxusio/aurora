package ai

import (
	"context"
	"errors"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
)

// PermissionDecision is returned by the user when approving or denying a tool call.
type PermissionDecision struct {
	Allow  bool   `json:"allow"`
	Always bool   `json:"always,omitempty"` // remember for the remainder of the session
	Reason string `json:"reason,omitempty"`
}

// SessionGrants exposes only the actual remembered scopes, never pending input.
func (g *PermissionGate) SessionGrants(sessionID, action, resource string, revoke bool) []PermissionRule {
	g.mu.Lock()
	defer g.mu.Unlock()
	prefix := sessionID + "\x00"
	if revoke {
		delete(g.allowedKeys, prefix+action+"\x00"+resource)
	}
	result := []PermissionRule{}
	for key := range g.allowedKeys {
		if !strings.HasPrefix(key, prefix) {
			continue
		}
		parts := strings.SplitN(strings.TrimPrefix(key, prefix), "\x00", 2)
		if len(parts) == 2 {
			result = append(result, PermissionRule{Action: parts[0], Resource: parts[1], Effect: "allow"})
		}
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].Action+result[i].Resource < result[j].Action+result[j].Resource
	})
	return result
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
			key := p.question.SessionID + "\x00" + p.question.Action + "\x00" + rememberPattern(p.question.Action, p.question.Resource)
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
	if action == "edit" || action == "write" {
		dir := filepath.ToSlash(filepath.Dir(strings.TrimSpace(resource)))
		if dir == "." || dir == "" {
			return "./*"
		}
		return strings.TrimSuffix(dir, "/") + "/*"
	}
	return "*"
}

// AlwaysAllowScope is what "allow for this session" remembers for a question:
// the first word of a shell command, or every use of the action.
func AlwaysAllowScope(action, resource string) string { return rememberPattern(action, resource) }

// Sensitive files and high-impact commands must never inherit a broad
// session-wide "always allow" pattern.
func rememberPattern(action, resource string) string {
	if isSensitiveFile(resource) || (action == "shell" && shellTouchesSensitive(resource)) {
		return resource
	}
	if action == "shell" && isHighRiskShellCommand(resource) {
		return resource
	}
	return savePattern(action, resource)
}

// Permission reasons, by stable code. The text is what Evaluate returns.
const (
	reasonPlanReadOnly     = "Plan mode is read-only: switch to Build mode to edit or write files."
	reasonPlanShell        = "Plan mode requires confirmation for non-read-only shell commands."
	reasonExploreReadOnly  = "Explore subagent is strictly read-only."
	reasonExploreShell     = "Explore subagent cannot run mutating shell commands."
	reasonSensitiveFile    = "Accessing potential secret or environment credential file"
	reasonRepeatedCall     = "Repeated identical tool call detected (3 times in a row)"
	reasonHighRiskShell    = "High-impact shell command requires confirmation"
	reasonFileModification = "File modification requires approval"
	reasonShellCommand     = "Shell command execution requires approval"
)

var reasonCodes = map[string]string{
	reasonPlanReadOnly:     "plan_read_only",
	reasonPlanShell:        "plan_shell",
	reasonExploreReadOnly:  "explore_read_only",
	reasonExploreShell:     "explore_shell",
	reasonSensitiveFile:    "sensitive_file",
	reasonRepeatedCall:     "repeated_call",
	reasonHighRiskShell:    "high_risk_shell",
	reasonFileModification: "file_modification",
	reasonShellCommand:     "shell_command",
}

// PermissionReasonCode names a reason from Evaluate; "" for text it does not know
// (the doom-loop question in runner.go carries its own long sentence).
func PermissionReasonCode(reason string) string {
	if code, ok := reasonCodes[reason]; ok {
		return code
	}
	if strings.HasPrefix(reason, "Agent invoked the exact same tool") {
		return "repeated_call"
	}
	return ""
}

// Evaluate decides ("allow", "ask", "deny") and a human-readable reason.
func (g *PermissionGate) Evaluate(sessionID, agentMode, permMode, action, resource string) (string, string) {
	return g.EvaluateWithRules(sessionID, agentMode, permMode, action, resource, nil)
}

// EvaluateWithRules applies the ordered client policy before the normal Ask /
// Auto defaults. The last matching rule wins, while plan/explore restrictions,
// doom-loop protection and broad sensitive/high-risk grants remain hard guards.
func (g *PermissionGate) EvaluateWithRules(sessionID, agentMode, permMode, action, resource string, rules []PermissionRule) (string, string) {
	ruleEffect, ruleMatched, ruleExact := matchingPermissionRule(rules, action, resource)
	if ruleMatched && ruleEffect == "deny" {
		return "deny", "操作被权限规则拒绝"
	}
	// Plan & Explore hard guardrails
	if agentMode == "plan" {
		if action == "write" || action == "edit" {
			return "deny", reasonPlanReadOnly
		}
		if action == "shell" && !isReadOnlyShellCommand(resource) {
			return "ask", reasonPlanShell
		}
	}
	if agentMode == "explore" {
		if action == "write" || action == "edit" || action == "subagent" {
			return "deny", reasonExploreReadOnly
		}
		if action == "shell" && !isReadOnlyShellCommand(resource) {
			return "deny", reasonExploreShell
		}
	}

	// Sensitive credential files (.env, private keys)
	if action == "read" || action == "edit" || action == "write" {
		if isSensitiveFile(resource) {
			if ruleMatched && ruleEffect == "deny" {
				return "deny", reasonSensitiveFile
			}
			// A wildcard allow is not enough for a secret. An exact, explicit
			// policy entry is an intentional opt-in; otherwise ask per session.
			if !(ruleMatched && ruleEffect == "allow" && ruleExact) && !g.isRemembered(sessionID, action, resource) {
				return "ask", reasonSensitiveFile
			}
		}
	}

	if action == "doom_loop" {
		return "ask", reasonRepeatedCall
	}
	if ruleMatched {
		switch ruleEffect {
		case "deny":
			if action == "read" || action == "edit" || action == "write" {
				return "deny", reasonSensitiveFile
			}
			return "deny", "操作被权限规则拒绝"
		case "ask":
			if g.isRemembered(sessionID, action, resource) {
				return "allow", ""
			}
			return "ask", ruleReason(action)
		case "allow":
			// Never let a wildcard policy silently bless secrets or destructive
			// commands. An explicit exact rule is the only way to opt in.
			if (isSensitiveFile(resource) || (action == "shell" && (isHighRiskShellCommand(resource) || shellTouchesSensitive(resource)))) && !ruleExact {
				break
			}
			return "allow", ""
		}
	}

	if permMode == "auto" {
		// Even in auto mode, guard clearly catastrophic system-wide commands unless explicitly approved.
		if action == "shell" && (isHighRiskShellCommand(resource) || shellTouchesSensitive(resource)) && !g.isRemembered(sessionID, action, resource) {
			return "ask", reasonHighRiskShell
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
		return "ask", reasonFileModification
	case "shell":
		if isReadOnlyShellCommand(resource) || g.isRemembered(sessionID, action, resource) {
			return "allow", ""
		}
		return "ask", reasonShellCommand
	default:
		return "allow", ""
	}
}

func ruleReason(action string) string {
	switch action {
	case "edit", "write":
		return reasonFileModification
	case "shell":
		return reasonShellCommand
	default:
		return "该操作需要按权限规则确认"
	}
}

func matchingPermissionRule(rules []PermissionRule, action, resource string) (effect string, matched bool, exact bool) {
	for i := len(rules) - 1; i >= 0; i-- {
		r := rules[i]
		if r.Effect != "allow" && r.Effect != "ask" && r.Effect != "deny" {
			continue
		}
		if r.Action != "*" && r.Action != action {
			continue
		}
		if !permissionGlobMatch(r.Resource, resource) {
			continue
		}
		return r.Effect, true, r.Resource == resource
	}
	return "", false, false
}

func permissionGlobMatch(pattern, value string) bool {
	pattern = strings.ReplaceAll(pattern, "\\", "/")
	value = strings.ReplaceAll(value, "\\", "/")
	// Small wildcard matcher: '*' spans any characters (including path
	// separators), '?' spans one character. This matches shell permission
	// resources such as "git status *" and "*.env" without regex surprises.
	pi, vi, star, mark := 0, 0, -1, 0
	for vi < len(value) {
		if pi < len(pattern) && (pattern[pi] == '?' || pattern[pi] == value[vi]) {
			pi++
			vi++
			continue
		}
		if pi < len(pattern) && pattern[pi] == '*' {
			star = pi
			mark = vi
			pi++
			continue
		}
		if star >= 0 {
			pi = star + 1
			mark++
			vi = mark
			continue
		}
		return false
	}
	for pi < len(pattern) && pattern[pi] == '*' {
		pi++
	}
	return pi == len(pattern)
}

func (g *PermissionGate) isRemembered(sessionID, action, resource string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if isSensitiveFile(resource) || (action == "shell" && shellTouchesSensitive(resource)) || (action == "shell" && isHighRiskShellCommand(resource)) {
		return g.allowedKeys[sessionID+"\x00"+action+"\x00"+resource]
	}
	if action == "edit" || action == "write" {
		dir := filepath.ToSlash(filepath.Dir(strings.TrimSpace(resource)))
		for {
			pattern := strings.TrimSuffix(dir, "/") + "/*"
			if dir == "." || dir == "" {
				pattern = "./*"
			}
			if g.allowedKeys[sessionID+"\x00"+action+"\x00"+pattern] {
				return true
			}
			parent := filepath.ToSlash(filepath.Dir(dir))
			if parent == dir || dir == "." || dir == "" {
				break
			}
			dir = parent
		}
		return false
	}
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
	if q.ReasonCode == "" {
		q.ReasonCode = PermissionReasonCode(q.Reason)
	}
	if q.AlwaysScope == "" {
		q.AlwaysScope = AlwaysAllowScope(q.Action, q.Resource)
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
	// PowerShell aliases/functions and expression syntax differ from POSIX.
	// Do not incorrectly auto-approve a Windows command using the Unix allowlist.
	if runtime.GOOS == "windows" {
		return false
	}
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
	if shellTouchesSensitive(trimmed) {
		return false
	}
	if prog == "git" && len(fields) >= 2 {
		for _, f := range fields[2:] {
			if strings.HasPrefix(f, "--output=") || f == "--output" || f == "-o" {
				return false
			}
		}
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
			if f == "-delete" || f == "-exec" || f == "-execdir" || f == "-ok" || f == "-fprint" || f == "-fprintf" || f == "-fls" {
				return false
			}
		}
		return true
	}
	if prog == "rg" {
		for _, f := range fields[1:] {
			if f == "--pre" || strings.HasPrefix(f, "--pre=") || f == "--passthru" {
				return false
			}
		}
		return true
	}
	if prog == "date" {
		for _, f := range fields[1:] {
			if f == "-s" || f == "--set" || strings.HasPrefix(f, "--set=") {
				return false
			}
		}
	}
	return readOnlyCmds[prog]
}

func shellTouchesSensitive(cmd string) bool {
	for _, field := range strings.Fields(cmd) {
		field = strings.Trim(field, "\"'()[]{}")
		lower := strings.ToLower(field)
		if strings.Contains(lower, "/etc/shadow") || strings.Contains(lower, "\\etc\\shadow") || strings.Contains(lower, "agent.json") || isSensitiveFile(field) {
			return true
		}
	}
	return false
}

func isHighRiskShellCommand(cmd string) bool {
	lower := " " + strings.ToLower(cmd) + " "
	highRisk := []string{
		"remove-item", "format-volume", "clear-disk", "initialize-disk", "stop-computer", "restart-computer", "diskpart", "bcdedit", " reg delete ", " rd /s", " rmdir /s", " del /s",
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
