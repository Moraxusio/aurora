//go:build linux

package terminal

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The agent carries its own tmux (static, musl; agent/tools/tmux) and a small
// terminfo set (v2 tmuxbin.go). The binary is unpacked once into
// StateDir/bin/tmux-<sha12>, content-addressed, so an upgrade that brings
// another tmux never overwrites the file a running tmux server was started
// from. tmux clients must match their server, so commands keep using the
// binary the running server started with (StateDir/tmux-server) until that
// server is gone.

// Bundle is the embedded tmux build: tmux.gz, terminfo.tar.gz and
// manifest.txt ("<sha256>  <name>" lines). Empty in a development build.
type Bundle interface {
	ReadFile(name string) ([]byte, error)
}

type tmuxRuntime struct {
	once     sync.Once
	mu       sync.Mutex
	path     string // binary for commands to the running server
	latest   string // binary new servers start with
	version  string
	bundled  bool
	note     string
	terminfo string
}

// managedConf is the tmux setup every Aurora 3 server gets (v2 tmuxconf.go),
// so behaviour does not depend on a ~/.tmux.conf the machine may carry.
var managedConf = []string{
	"# managed by aurora3-agent and rewritten on every start.",
	"set -g escape-time 0",
	"unbind-key -a",
	"bind-key -n C-d detach-client",
	"bind-key -n PageUp copy-mode -u",
	"bind-key -n PageDown send-keys -X page-down",
	"set -g mouse on",
	// The wheel, by what is in the pane. tmux's own binding hands the wheel to
	// a full-screen program as a mouse report, and a program that did not ask
	// for the mouse (less, man, git log) throws that away, so it never
	// scrolled. Here: a program that asked for the mouse (vim, htop, opencode)
	// gets the report; any other full-screen program gets arrow keys; a plain
	// shell scrolls tmux's history (copy mode, left again at the bottom).
	"bind-key -n WheelUpPane if-shell -F '#{mouse_any_flag}' { send-keys -M } { if-shell -F '#{alternate_on}' { send-keys -N 3 Up } { if-shell -F '#{pane_in_mode}' { send-keys -M } { copy-mode -e } } }",
	"bind-key -n WheelDownPane if-shell -F '#{mouse_any_flag}' { send-keys -M } { if-shell -F '#{alternate_on}' { send-keys -N 3 Down } { send-keys -M } }",
	"set -g history-limit 100000",
	"set -g status-position top",
	"set -g status-style 'bg=#111827,fg=#d1d5db'",
	"set -g status-left '#[fg=#60a5fa,bold] #S '",
	"set -g status-right '#[fg=#9ca3af]%Y-%m-%d %H:%M '",
	"set -g pane-border-style 'fg=#374151'",
	"set -g pane-active-border-style 'fg=#60a5fa'",
}

func (e *Env) binDir() string     { return filepath.Join(e.StateDir, "bin") }
func (e *Env) confPath() string   { return filepath.Join(e.StateDir, "tmux.conf") }
func (e *Env) recordPath() string { return filepath.Join(e.StateDir, "tmux-server") }

func (e *Env) tmuxBin() string {
	e.rt.once.Do(e.setup)
	e.rt.mu.Lock()
	defer e.rt.mu.Unlock()
	return e.rt.path
}

func (e *Env) terminfoDir() string {
	e.tmuxBin()
	e.rt.mu.Lock()
	defer e.rt.mu.Unlock()
	return e.rt.terminfo
}

func (e *Env) setup() {
	rt := &e.rt
	p, ver, err := e.unpackTmux()
	if err != nil {
		rt.note = "没有内置 tmux（" + err.Error() + "），改用系统 tmux"
		rt.latest = systemTmux()
		rt.path = rt.latest
		return
	}
	rt.latest, rt.version, rt.bundled = p, ver, true
	rt.path = p
	if dir, err := e.unpackTerminfo(); err == nil {
		rt.terminfo = dir
	}
	// A server started by an earlier tmux keeps being driven by that binary.
	if rec := e.recordedTmux(); rec != "" && rec != rt.latest && isFile(rec) && e.serverAlive(rec) {
		rt.path = rec
		rt.note = "正在运行的会话由上一版 tmux 托管；它们全部结束后，新会话改用内置的 " + rt.version
	}
	e.prune(rt.path, rt.latest)
	_ = e.writeConf()
}

func systemTmux() string {
	if p, err := exec.LookPath("tmux"); err == nil {
		return p
	}
	return "tmux"
}

func (e *Env) bundleFile(name string) ([]byte, error) {
	if e.Bundle == nil {
		return nil, errors.New("开发构建")
	}
	return e.Bundle.ReadFile(name)
}

func (e *Env) manifestSHA(name string) string {
	m, err := e.bundleFile("manifest.txt")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(m), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[1] == name && len(f[0]) == 64 {
			return f[0]
		}
	}
	return ""
}

func (e *Env) unpackTmux() (string, string, error) {
	gz, err := e.bundleFile("tmux.gz")
	if err != nil {
		return "", "", errors.New("开发构建")
	}
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		return "", "", err
	}
	raw, err := io.ReadAll(io.LimitReader(zr, 64<<20))
	if err != nil {
		return "", "", err
	}
	sum := sha256.Sum256(raw)
	sha := hex.EncodeToString(sum[:])
	if want := e.manifestSHA("tmux"); want != sha {
		return "", "", errors.New("内置 tmux 校验失败")
	}
	if err := os.MkdirAll(e.binDir(), 0o755); err != nil {
		return "", "", err
	}
	path := filepath.Join(e.binDir(), "tmux-"+sha[:12])
	if !sameFile(path, sum[:]) {
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, raw, 0o755); err != nil {
			return "", "", err
		}
		if err := os.Rename(tmp, path); err != nil {
			os.Remove(tmp)
			return "", "", err
		}
	}
	ver := versionOf(path)
	if ver == "" {
		return "", "", errors.New("内置 tmux 无法运行")
	}
	return path, ver, nil
}

func versionOf(bin string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "-V").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func sameFile(path string, want []byte) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	got := sha256.Sum256(b)
	return bytes.Equal(got[:], want)
}

// unpackTerminfo extracts the bundled entries into StateDir/terminfo.
func (e *Env) unpackTerminfo() (string, error) {
	data, err := e.bundleFile("terminfo.tar.gz")
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	if want := e.manifestSHA("terminfo.tar.gz"); want != "" && want != sha {
		return "", errors.New("内置 terminfo 校验失败")
	}
	dir := filepath.Join(e.StateDir, "terminfo")
	marker := filepath.Join(dir, ".bundle")
	if b, err := os.ReadFile(marker); err == nil && strings.TrimSpace(string(b)) == sha {
		return dir, nil
	}
	tmp := dir + ".new"
	os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return "", err
	}
	zr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		name := filepath.Clean(strings.TrimPrefix(h.Name, "./"))
		if h.Typeflag != tar.TypeReg || name == "." || strings.HasPrefix(name, "..") || filepath.IsAbs(name) {
			continue
		}
		dst := filepath.Join(tmp, name)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return "", err
		}
		b, err := io.ReadAll(io.LimitReader(tr, 1<<20))
		if err != nil {
			return "", err
		}
		if err := os.WriteFile(dst, b, 0o644); err != nil {
			return "", err
		}
	}
	if err := os.WriteFile(filepath.Join(tmp, ".bundle"), []byte(sha+"\n"), 0o644); err != nil {
		return "", err
	}
	os.RemoveAll(dir)
	if err := os.Rename(tmp, dir); err != nil {
		return "", err
	}
	return dir, nil
}

func (e *Env) recordedTmux() string {
	b, err := os.ReadFile(e.recordPath())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func (e *Env) serverAlive(bin string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, bin, e.tmuxArgs("list-sessions")...).Run() == nil
}

// startingServer moves to the bundled binary before a new tmux server starts
// and records it as the one that server runs.
func (e *Env) startingServer() {
	e.tmuxBin()
	rt := &e.rt
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if !rt.bundled {
		return
	}
	if rt.path != rt.latest {
		rt.path, rt.note = rt.latest, ""
		e.prune(rt.path, rt.latest)
	}
	_ = os.WriteFile(e.recordPath(), []byte(rt.path+"\n"), 0o600)
}

// prune removes unpacked binaries nothing uses any more.
func (e *Env) prune(keep ...string) {
	ents, _ := os.ReadDir(e.binDir())
	for _, d := range ents {
		if !strings.HasPrefix(d.Name(), "tmux-") {
			continue
		}
		p := filepath.Join(e.binDir(), d.Name())
		used := false
		for _, k := range keep {
			used = used || k == p
		}
		if !used {
			os.Remove(p)
		}
	}
}

func (e *Env) writeConf() error {
	lines := managedConf
	if e.rt.terminfo != "" {
		lines = append(append([]string{}, lines...), "set -g default-terminal tmux-256color", "set -as terminal-features ',xterm-256color:RGB'")
	}
	tmp := e.confPath() + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, e.confPath())
}

// tmuxArgs prefixes UTF-8 mode, the agent's own socket (never the
// machine's default tmux, nor v2's "aurora") and its tmux.conf.
func (e *Env) tmuxArgs(args ...string) []string {
	pre := []string{"-u", "-L", e.socket()}
	if isFile(e.confPath()) {
		pre = append(pre, "-f", e.confPath())
	}
	return append(pre, args...)
}

func (e *Env) socket() string {
	if e.Socket != "" {
		return e.Socket
	}
	return DefaultSocket
}

func (e *Env) tmux(ctx context.Context, args ...string) (string, string, error) {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, e.tmuxBin(), e.tmuxArgs(args...)...)
	cmd.Env = e.cmdEnv()
	var out, errb strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	return out.String(), errb.String(), err
}

// cmdEnv is the environment for tmux commands: the agent's, with the
// bundled terminfo first.
func (e *Env) cmdEnv() []string {
	env := []string{"LANG=C.UTF-8"}
	if ti := e.terminfoDir(); ti != "" {
		env = append(env, "TERMINFO_DIRS="+ti+":")
	}
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "LANG=") || strings.HasPrefix(kv, "TERMINFO_DIRS=") {
			continue
		}
		env = append(env, kv)
	}
	return env
}

// Info describes the tmux in use (agent.info).
func (e *Env) Info() map[string]any {
	p := e.tmuxBin()
	e.rt.mu.Lock()
	defer e.rt.mu.Unlock()
	v := e.rt.version
	if p != e.rt.latest || v == "" {
		v = versionOf(p)
	}
	return map[string]any{"path": p, "version": v, "bundled": e.rt.bundled && p == e.rt.latest, "socket": e.socket(), "note": e.rt.note}
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

func isDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func shellQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", "'\\''") + "'" }

func (e *Env) fmtUnit() string {
	p := e.UnitPrefix
	if p == "" {
		p = UnitPrefix
	}
	return fmt.Sprintf("%s%d", p, time.Now().UnixMilli())
}
