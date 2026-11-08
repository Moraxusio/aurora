//go:build linux

// Package terminal is the "terminal" service (D-45): tmux sessions on the
// bundled tmux and attached terminal streams. It is v2's sessions.go and
// terminal.go with v3's names (D-71): the tmux socket is "aurora3", tmux
// servers run in aurora3-tmux-* units (D-35), and state lives under the
// agent's StateDir.
//
// Switching the service off (D-51, D-52, D-54) refuses new sessions and new
// attaches, and disconnects attached windows with a reason; tmux sessions
// keep running, and session.kill still works.
package terminal

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"

	"aurora3/internal/service"
	"aurora3/internal/wire"
)

const (
	ID = "terminal"
	// DefaultSocket is v3's tmux socket (v2 uses "aurora").
	DefaultSocket = "aurora3"
	// UnitPrefix names the transient units tmux servers run in (D-35). It is
	// not a prefix of v2's aurora-tmux-*, nor the other way round.
	UnitPrefix = "aurora3-tmux-"
)

// Auditor records one line per mutating operation (D-26).
type Auditor interface {
	Write(event string, fields map[string]any)
}

// Root is a file root; sessions may start in a folder under one.
type Root struct {
	ID   string
	Path string
}

// Env is everything the terminal service needs from the agent.
type Env struct {
	StateDir string
	Roots    []Root
	Audit    Auditor
	Bundle   Bundle
	Socket   string // tests: a private tmux socket
	// NoUnit starts tmux servers without systemd-run (tests, or an agent not
	// run by systemd). A real agent sets it false.
	NoUnit bool

	// Proxy returns the proxy environment for a new session, or an error that
	// says why the session cannot have one (the proxy service is off, or no
	// node is chosen). Nil means this agent has no proxy service (D-49).
	Proxy func() (map[string]string, error)

	rt       tmuxRuntime
	createMu sync.Mutex

	mu       sync.Mutex
	attached map[*attach]struct{}
}

type attach struct {
	cancel func(reason string)
}

var (
	sessionName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,48}$`)
)

// Service returns the terminal service.
func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ e *Env }

func (svc) ID() string { return ID }

// tmux is bundled; systemd-run keeps tmux servers out of the agent's cgroup.
func (svc) Dependencies() []service.Dependency {
	return []service.Dependency{{Name: "systemd-run", Required: true, Purpose: "让终端会话独立于 agent 运行（D-35）"}}
}

func (v svc) Operations() []service.Operation {
	e := v.e
	return []service.Operation{
		{Name: "session.list", Handle: e.sessionList},
		{Name: "session.create", Handle: e.sessionCreate},
		{Name: "session.cwd", Handle: e.sessionCwd},
		{Name: "session.capture", Handle: e.sessionCapture},
		{Name: "terminal", Stream: e.terminal},
	}
}

// Switched disconnects attached windows when the service goes off (D-51).
func (v svc) Switched(on bool) {
	if on {
		return
	}
	e := v.e
	e.mu.Lock()
	list := make([]*attach, 0, len(e.attached))
	for a := range e.attached {
		list = append(list, a)
	}
	e.mu.Unlock()
	for _, a := range list {
		a.cancel("终端服务已关闭；会话仍在运行")
	}
}

// KillOp is session.kill. It belongs to the entry, not to the service, so it
// works while terminal is off (D-52).
func (e *Env) KillOp() service.Handler { return e.sessionKill }

func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

func checkName(name string) error {
	if !sessionName.MatchString(name) {
		return wire.Errf(wire.CodeBadRequest, "会话名只能包含字母、数字、点、下划线和连字符（最多 48 个）")
	}
	return nil
}

type sessionArgs struct {
	Name  string `json:"name"`
	Root  string `json:"root,omitempty"`
	Path  string `json:"path,omitempty"`
	Proxy bool   `json:"proxy,omitempty"` // D-47: decided here, not changed later (D-48)
}

type sessionRow struct {
	Name     string `json:"name"`
	Attached int    `json:"attached"`
	Windows  int    `json:"windows"`
	Created  int64  `json:"created"`
}

func (e *Env) exists(ctx context.Context, name string) bool {
	_, _, err := e.tmux(ctx, "has-session", "-t", "="+name)
	return err == nil
}

// Sessions lists the sessions (also used by uninstall checks, D-31).
func (e *Env) Sessions(ctx context.Context) []sessionRow {
	out, _, _ := e.tmux(ctx, "list-sessions", "-F", "#{session_name}|#{session_attached}|#{session_windows}|#{session_created}")
	rows := []sessionRow{}
	for _, line := range strings.Split(out, "\n") {
		p := strings.Split(line, "|")
		if len(p) != 4 {
			continue
		}
		a, _ := strconv.Atoi(p[1])
		w, _ := strconv.Atoi(p[2])
		c, _ := strconv.ParseInt(p[3], 10, 64)
		rows = append(rows, sessionRow{p[0], a, w, c})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows
}

func (e *Env) sessionList(ctx context.Context, _ json.RawMessage) (any, error) {
	return map[string]any{"sessions": e.Sessions(ctx), "tmux": e.Info()}, nil
}

// innerCommand is the shell a new session runs: the bundled terminfo first,
// then a login shell (v2 innerCommand, without session_user and proxy,
// which come with G2.8).
//
// envFile, when set, holds the proxy variables of a session made with proxy:true
// (D-50): they carry a password, so they are not in tmux's argument list, which
// any local user can read. rcFile is the bash startup file that reads them.
//
// A login shell runs /etc/profile.d and ~/.profile, and those may set or clear
// a proxy of their own, so variables exported before the shell starts are not
// reliable. For bash the session therefore runs in two steps: the login shell,
// which does its usual startup, then an interactive bash whose startup file
// reads the user's own bashrc and, last, the proxy variables, and deletes the
// file. Another shell gets the variables before it starts, which a startup
// file of its own can still override (the reply says which one applied).
func (e *Env) innerCommand(envFile, rcFile string) string {
	var b strings.Builder
	b.WriteString("export AURORA3_SESSION=1; ")
	if ti := e.terminfoDir(); ti != "" {
		b.WriteString("export TERMINFO_DIRS=" + shellQuote(ti) + ":\"${TERMINFO_DIRS:-}\"; ")
	}
	b.WriteString("if [ -z \"$SHELL\" ] || [ ! -x \"$SHELL\" ]; then export SHELL=" + shellQuote(loginShell()) + "; fi; ")
	if envFile != "" {
		qe := shellQuote(envFile)
		b.WriteString("case \"${SHELL##*/}\" in bash) export AURORA3_ENVFILE=" + qe + " AURORA3_RC=" + shellQuote(rcFile) +
			"; exec \"$SHELL\" -l -c 'exec \"$SHELL\" --rcfile \"$AURORA3_RC\" -i';; esac; ")
		b.WriteString("if [ -r " + qe + " ]; then . " + qe + "; rm -f " + qe + "; fi; ")
	}
	b.WriteString("exec \"$SHELL\" -l")
	return b.String()
}

func loginShell() string {
	for _, p := range []string{"/bin/bash", "/usr/bin/bash", "/bin/sh"} {
		if isFile(p) {
			return p
		}
	}
	return "/bin/sh"
}

// ensure creates the session when it is missing, starting in dir if given.
func (e *Env) ensure(ctx context.Context, name, dir string, withProxy bool) error {
	if err := checkName(name); err != nil {
		return err
	}
	e.createMu.Lock()
	defer e.createMu.Unlock()
	if e.exists(ctx, name) {
		return nil
	}
	// Without a folder, start in the home directory, not in the agent's own
	// working directory (/ under systemd, wherever it was started by hand).
	if dir == "" {
		if h, err := os.UserHomeDir(); err == nil && isDir(h) {
			dir = h
		}
	}
	newArgs := []string{"new-session", "-d", "-s", name}
	if dir != "" {
		newArgs = append(newArgs, "-c", dir)
	}
	_, _, lerr := e.tmux(ctx, "list-sessions")
	noServer := lerr != nil
	if noServer {
		e.startingServer()
	}
	envFile, rcFile := "", ""
	failed := false
	if withProxy {
		vars, err := e.proxyVars()
		if err != nil {
			return err
		}
		if rcFile, err = e.writeSessionRC(); err != nil {
			return wire.Errf(wire.CodeInternal, "写入会话启动文件失败：%v", err)
		}
		envFile, err = e.writeSessionEnv(name, vars)
		if err != nil {
			return wire.Errf(wire.CodeInternal, "写入会话环境失败：%v", err)
		}
		// The session deletes the file once it has read it, which happens after
		// this function has returned (tmux starts the shell on its own), so it
		// is not deleted on success. If starting tmux fails nobody will read
		// it, and the error path below removes it.
		defer func() {
			if failed {
				_ = os.Remove(envFile)
			}
		}()
	}
	args := e.tmuxArgs(append(newArgs, loginShell(), "-c", e.innerCommand(envFile, rcFile))...)
	cmdPath, cmdArgs := e.tmuxBin(), args
	// A tmux server started from the agent would live in the agent's cgroup
	// and die when the agent restarts or upgrades, so it gets its own unit
	// (D-35). Without systemd (tests) it starts directly.
	if noServer && !e.NoUnit {
		sr, err := exec.LookPath("systemd-run")
		if err != nil {
			return wire.Errf(wire.CodeUnavailable, "缺少 systemd-run，无法创建会话")
		}
		home, _ := os.UserHomeDir()
		pre := []string{"--quiet", "--collect", "--unit", fmtUnit(),
			"--property", "Type=forking", "--setenv", "HOME=" + home, "--setenv", "LANG=C.UTF-8", "--setenv", "TERM=xterm-256color",
			"--setenv", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"}
		if ti := e.terminfoDir(); ti != "" {
			pre = append(pre, "--setenv", "TERMINFO_DIRS="+ti+":")
		}
		cmdPath = sr
		cmdArgs = append(append(pre, e.tmuxBin()), args...)
	}
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, cmdPath, cmdArgs...)
	cmd.Env = e.cmdEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "duplicate session") && e.exists(ctx, name) {
			failed = true // somebody else made it: this call's file is not used
			return nil
		}
		failed = true
		return wire.Errf(wire.CodeInternal, "创建会话失败：%s", strings.TrimSpace(string(out)))
	}
	return nil
}

func (e *Env) sessionCreate(ctx context.Context, raw json.RawMessage) (any, error) {
	var a sessionArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Name == "" {
		a.Name = "main"
	}
	dir := ""
	if a.Root != "" {
		d, err := e.sessionDir(a.Root, a.Path)
		if err != nil {
			return nil, err
		}
		dir = d
	}
	existed := e.exists(ctx, a.Name)
	if err := e.ensure(ctx, a.Name, dir, a.Proxy); err != nil {
		return nil, err
	}
	e.audit("session.create", map[string]any{"name": a.Name, "proxy": a.Proxy && !existed})
	// A session that was already there keeps the environment it started with
	// (D-48): say so, so a client does not claim it now goes through the proxy.
	return map[string]any{"name": a.Name, "proxy": a.Proxy && !existed, "existed": existed}, nil
}

func (e *Env) audit(event string, f map[string]any) {
	if e.Audit != nil {
		e.Audit.Write(event, f)
	}
}

func (e *Env) sessionDir(root, p string) (string, error) {
	for _, r := range e.Roots {
		if r.ID != root {
			continue
		}
		rel := strings.TrimPrefix(p, "/")
		for _, part := range strings.Split(rel, "/") {
			if part == ".." {
				return "", wire.Errf(wire.CodeBadRequest, "路径无效")
			}
		}
		dir := r.Path
		if rel != "" {
			dir = r.Path + "/" + rel
		}
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			return "", wire.Errf(wire.CodeNotFound, "文件夹不存在")
		}
		return dir, nil
	}
	return "", wire.Errf(wire.CodeNotFound, "未知的根目录：%s", root)
}

func (e *Env) sessionCwd(ctx context.Context, raw json.RawMessage) (any, error) {
	var a sessionArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := checkName(a.Name); err != nil {
		return nil, err
	}
	out, errOut, err := e.tmux(ctx, "display-message", "-p", "-t", "="+a.Name+":", "#{pane_current_path}")
	if err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "会话不存在：%s", strings.TrimSpace(errOut))
	}
	return map[string]any{"cwd": strings.TrimSpace(out)}, nil
}

// sessionCapture returns the text of the session's active pane: the visible
// screen, plus up to `history` lines of scrollback (at most 10000), with
// wrapped lines joined.
func (e *Env) sessionCapture(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Name    string `json:"name"`
		History int    `json:"history"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := checkName(a.Name); err != nil {
		return nil, err
	}
	args := []string{"capture-pane", "-p", "-J", "-t", "=" + a.Name + ":"}
	if h := min(max(a.History, 0), 10000); h > 0 {
		args = append(args, "-S", "-"+strconv.Itoa(h))
	}
	out, errOut, err := e.tmux(ctx, args...)
	if err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "会话不存在：%s", strings.TrimSpace(errOut))
	}
	return map[string]any{"text": out}, nil
}

// sessionKill removes the session and every process still in its panes'
// Unix sessions (v2 killSession). Daemons that called setsid are left alone.
func (e *Env) sessionKill(ctx context.Context, raw json.RawMessage) (any, error) {
	var a sessionArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := checkName(a.Name); err != nil {
		return nil, err
	}
	if !e.exists(ctx, a.Name) {
		return nil, wire.Errf(wire.CodeNotFound, "会话不存在")
	}
	panes, _, _ := e.tmux(ctx, "list-panes", "-s", "-t", "="+a.Name, "-F", "#{pane_pid}")
	sids := map[int]bool{}
	for _, p := range strings.Fields(panes) {
		if pid, err := strconv.Atoi(p); err == nil {
			if sid := procSID(pid); sid > 1 {
				sids[sid] = true
			}
		}
	}
	if _, errOut, err := e.tmux(ctx, "kill-session", "-t", "="+a.Name); err != nil && e.exists(ctx, a.Name) {
		return nil, wire.Errf(wire.CodeInternal, "结束会话失败：%s", strings.TrimSpace(errOut))
	}
	forced := 0
	for _, step := range []struct {
		sig  syscall.Signal
		wait time.Duration
	}{{0, time.Second}, {syscall.SIGTERM, 2 * time.Second}, {syscall.SIGKILL, time.Second}} {
		if len(sids) == 0 {
			break
		}
		left := procsIn(sids)
		if len(left) == 0 {
			break
		}
		if step.sig != 0 {
			forced = len(left)
			for _, pid := range left {
				_ = syscall.Kill(pid, step.sig)
			}
		}
		deadline := time.Now().Add(step.wait)
		for time.Now().Before(deadline) && len(procsIn(sids)) > 0 {
			time.Sleep(100 * time.Millisecond)
		}
	}
	e.audit("session.kill", map[string]any{"name": a.Name, "forced": forced})
	return map[string]any{"name": a.Name, "forced": forced}, nil
}

func procSID(pid int) int {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0
	}
	i := strings.LastIndexByte(string(b), ')')
	if i < 0 {
		return 0
	}
	f := strings.Fields(string(b)[i+1:])
	if len(f) < 4 {
		return 0
	}
	sid, _ := strconv.Atoi(f[3])
	return sid
}

func procsIn(sids map[int]bool) []int {
	ents, _ := os.ReadDir("/proc")
	me := os.Getpid()
	var out []int
	for _, d := range ents {
		pid, err := strconv.Atoi(d.Name())
		if err != nil || pid == me {
			continue
		}
		if sids[procSID(pid)] {
			out = append(out, pid)
		}
	}
	return out
}

type terminalArgs struct {
	Name string `json:"name"`
	Cols int    `json:"cols"`
	Rows int    `json:"rows"`
}

func clampSize(cols, rows int) *pty.Winsize {
	cols = max(20, min(500, cols))
	rows = max(4, min(200, rows))
	return &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)}
}

// terminal attaches to an existing session (v2 terminal.go). It never
// creates one, so a reconnect after "kill" cannot resurrect a session.
// Frames: 'D' carries terminal bytes both ways; 'J' carries
// wire.TerminalControl (resize, ping/pong, close; exit, detached).
func (e *Env) terminal(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var a terminalArgs
	if err := decode(raw, &a); err != nil {
		return err
	}
	if err := checkName(a.Name); err != nil {
		return err
	}
	if !e.exists(ctx, a.Name) {
		return wire.Errf(wire.CodeNotFound, "会话已结束")
	}
	cmd := exec.Command(e.tmuxBin(), e.tmuxArgs("attach-session", "-t", "="+a.Name)...)
	env := []string{"TERM=xterm-256color"}
	for _, kv := range e.cmdEnv() {
		if !strings.HasPrefix(kv, "TERM=") {
			env = append(env, kv)
		}
	}
	cmd.Env = env
	ptmx, err := pty.StartWithSize(cmd, clampSize(a.Cols, a.Rows))
	if err != nil {
		return wire.Errf(wire.CodeInternal, "无法打开终端：%v", err)
	}
	var wmu sync.Mutex
	send := func(typ byte, b []byte) error {
		wmu.Lock()
		defer wmu.Unlock()
		_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
		return wire.WriteFrame(st, typ, b)
	}
	if err := send(wire.TypeJSON, mustJSON(wire.Response{OK: true})); err != nil {
		ptmx.Close()
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
		return nil
	}
	stop := make(chan struct{})
	var once sync.Once
	finish := func() { once.Do(func() { close(stop); st.Close(); ptmx.Close() }) }
	defer finish()

	// Switching the service off ends this window with a reason (D-51).
	kicked := make(chan string, 1)
	me := &attach{cancel: func(reason string) {
		select {
		case kicked <- reason:
		default:
		}
	}}
	e.mu.Lock()
	if e.attached == nil {
		e.attached = map[*attach]struct{}{}
	}
	e.attached[me] = struct{}{}
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		delete(e.attached, me)
		e.mu.Unlock()
	}()

	ptyDone := make(chan struct{})
	go func() { // pty -> client
		defer close(ptyDone)
		buf := make([]byte, 64*1024)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 && send(wire.TypeData, buf[:n]) != nil {
				finish()
				return
			}
			if err != nil {
				return
			}
		}
	}()
	go func() { // client -> pty
		defer finish()
		for {
			typ, payload, err := wire.ReadFrame(st)
			if err != nil {
				return
			}
			switch typ {
			case wire.TypeData:
				if _, err := ptmx.Write(payload); err != nil {
					return
				}
			case wire.TypeJSON:
				var c wire.TerminalControl
				if json.Unmarshal(payload, &c) != nil {
					continue
				}
				switch c.Type {
				case "resize":
					_ = pty.Setsize(ptmx, clampSize(c.Cols, c.Rows))
				case "ping":
					_ = send(wire.TypeJSON, mustJSON(wire.TerminalControl{Type: "pong", Code: c.Code}))
				case "close":
					return
				}
			}
		}
	}()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		select {
		case <-ptyDone:
		case <-time.After(500 * time.Millisecond):
		}
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
		// The attach client ending does not mean the session ended (detach,
		// or killed while the agent restarts). Only a session that is gone
		// is "exit"; otherwise the client attaches again.
		kind := "exit"
		if e.stillThere(a.Name) {
			kind = "detached"
		}
		_ = send(wire.TypeJSON, mustJSON(wire.TerminalControl{Type: kind, Code: code}))
		return nil
	case reason := <-kicked:
		_ = send(wire.TypeJSON, mustJSON(map[string]any{"type": "closed", "reason": reason}))
	case <-stop:
	case <-ctx.Done():
		// The agent is going away (restart, upgrade); the session is not.
		_ = send(wire.TypeJSON, mustJSON(wire.TerminalControl{Type: "detached", Code: -1}))
	}
	// Detach only: the tmux session keeps running.
	_ = cmd.Process.Signal(syscall.SIGHUP)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
	return nil
}

func (e *Env) stillThere(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return e.exists(ctx, name)
}

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
