//go:build linux

package install

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/monitor"
	"aurora3/internal/wire"
)

// Systemd is the real System: systemctl and systemd-analyze.
type Systemd struct {
	// Socket is the instance's tmux socket; empty is the default instance's.
	Socket string
}

func run(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var out bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	if ctx.Err() != nil {
		err = fmt.Errorf("超时（%s）", timeout)
	}
	return strings.TrimSpace(out.String()), err
}

func systemctl(args ...string) error {
	out, err := run(90*time.Second, "systemctl", args...)
	if err != nil {
		if out != "" {
			return fmt.Errorf("systemctl %s：%v：%s", strings.Join(args, " "), err, out)
		}
		return fmt.Errorf("systemctl %s：%v", strings.Join(args, " "), err)
	}
	return nil
}

// Available requires systemd as init and the three programs the installer
// and the terminal service use (D-35: tmux runs under systemd-run).
func (Systemd) Available() error {
	if !isDir("/run/systemd/system") {
		return errors.New("这台机器没有以 systemd 启动，不支持安装")
	}
	for _, c := range []string{"systemctl", "systemd-run", "systemd-analyze"} {
		if _, err := exec.LookPath(c); err != nil {
			return fmt.Errorf("缺少 %s，不支持安装", c)
		}
	}
	return nil
}

func (Systemd) IsActive(unit string) bool {
	_, err := run(15*time.Second, "systemctl", "is-active", "--quiet", unit)
	return err == nil
}

func (Systemd) IsEnabled(unit string) bool {
	_, err := run(15*time.Second, "systemctl", "is-enabled", "--quiet", unit)
	return err == nil
}

func (Systemd) DaemonReload() error       { return systemctl("daemon-reload") }
func (Systemd) Enable(unit string) error  { return systemctl("enable", unit) }
func (Systemd) Disable(unit string) error { return systemctl("disable", unit) }
func (Systemd) Restart(unit string) error { return systemctl("restart", unit) }
func (Systemd) Stop(unit string) error    { return systemctl("stop", unit) }

// ResetFailed fails harmlessly when the unit is not loaded or not failed.
func (Systemd) ResetFailed(unit string) { _ = systemctl("reset-failed", unit) }

func (Systemd) Units(pattern string) []string {
	out, err := run(15*time.Second, "systemctl", "list-units", "--all", "--plain", "--no-legend", pattern)
	if err != nil {
		return nil
	}
	var units []string
	for _, l := range strings.Split(out, "\n") {
		if f := strings.Fields(l); len(f) > 0 && strings.HasPrefix(f[0], strings.TrimSuffix(pattern, "*")) {
			units = append(units, f[0])
		}
	}
	return units
}

// tmuxBins are the tmux binaries the terminal service unpacked; a tmux client
// must match its server, so each is tried.
func tmuxBins(stateDir string) []string {
	m, _ := filepath.Glob(filepath.Join(stateDir, "bin", "tmux-*"))
	if p, err := exec.LookPath("tmux"); err == nil {
		m = append(m, p)
	}
	return m
}

// terminalSocket is the terminal service's tmux socket (terminal.DefaultSocket).
const terminalSocket = "aurora3"

func (s Systemd) socket() string {
	if s.Socket != "" {
		return s.Socket
	}
	return terminalSocket
}

func (s Systemd) TmuxSessions(stateDir string) ([]string, error) {
	for _, b := range tmuxBins(stateDir) {
		out, err := run(10*time.Second, b, "-L", s.socket(), "list-sessions", "-F", "#{session_name}")
		if err != nil {
			continue // no server, or a mismatched client: try the next binary
		}
		var names []string
		for _, l := range strings.Split(out, "\n") {
			if l = strings.TrimSpace(l); l != "" {
				names = append(names, l)
			}
		}
		return names, nil
	}
	return nil, nil
}

func (s Systemd) KillTmux(stateDir string) error {
	for _, b := range tmuxBins(stateDir) {
		_, _ = run(10*time.Second, b, "-L", s.socket(), "kill-server")
	}
	return nil
}

// VerifyUnit runs systemd-analyze verify. It exits 0 on some errors in the
// file (an unknown value is only a warning), so any message about this file
// counts as a failure too; messages about other units on the system do not.
func (Systemd) VerifyUnit(path string) error {
	out, err := run(60*time.Second, "systemd-analyze", "verify", path)
	var mine []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, path) || strings.HasPrefix(l, filepath.Base(path)+":") {
			mine = append(mine, l)
		}
	}
	if err != nil || len(mine) > 0 {
		if len(mine) == 0 && out != "" {
			mine = []string{out}
		}
		if len(mine) == 0 {
			mine = []string{err.Error()}
		}
		return errors.New(strings.Join(mine, "; "))
	}
	return nil
}

// BinaryVersion runs `path version`, which every aurora3-agent supports.
func (Systemd) BinaryVersion(path string) (string, error) {
	out, err := run(15*time.Second, path, "version")
	if err != nil {
		if out != "" {
			return "", fmt.Errorf("%v：%s", err, out)
		}
		return "", err
	}
	if f := strings.Fields(out); len(f) == 1 {
		return f[0], nil
	}
	return "", fmt.Errorf("无法识别的版本输出 %q", out)
}

// PortFree reports whether a TCP listener could take port on every address.
func (Systemd) PortFree(port int) bool {
	ln, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		return false
	}
	ln.Close()
	return true
}

// DialAgent is the real Dialer: pinned TLS, Hello, HelloReply (the same
// steps as the client, DESIGN 5.3).
func DialAgent(ctx context.Context, addr, pin, token string) (*wire.AgentInfo, error) {
	var d net.Dialer
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	defer raw.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = raw.SetDeadline(dl)
	}
	c := tls.Client(raw, wire.PinnedTLS(pin))
	if err := c.HandshakeContext(ctx); err != nil {
		return nil, err
	}
	if err := wire.WriteJSON(c, wire.Hello{Role: wire.RoleClient, Token: token, Version: wire.Version, Client: "aurora3-install"}); err != nil {
		return nil, err
	}
	var reply wire.HelloReply
	if err := wire.ReadJSON(c, &reply); err != nil {
		return nil, err
	}
	if !reply.OK {
		return nil, errors.New(reply.Error)
	}
	if reply.Server == nil {
		return nil, errors.New("HelloReply 缺少 server")
	}
	return reply.Server, nil
}

// DefaultRoots are the file roots of a new install (v2 DefaultRoots): the
// user's home, large local disks, WSL's Windows drives, and the system root.
func DefaultRoots(user string) []entry.Root {
	home := userHome("/etc/passwd", user)
	if home == "" {
		home = "/root"
	}
	roots := []entry.Root{{ID: "home", Label: "主目录 ~", Path: home}}
	used := map[string]bool{"home": true, "sys": true}
	for _, m := range monitor.LocalMounts() {
		mnt, _ := m["mount"].(string)
		total, _ := m["total"].(uint64)
		if mnt == "/" || strings.HasPrefix(mnt, "/boot") || total < 64<<30 || strings.HasPrefix(home+"/", mnt+"/") {
			continue
		}
		id := strings.ReplaceAll(strings.Trim(mnt, "/"), "/", "-")
		if used[id] {
			continue
		}
		used[id] = true
		roots = append(roots, entry.Root{ID: id, Label: mnt, Path: mnt})
	}
	roots = append(roots, wslDriveRoots()...)
	return append(roots, entry.Root{ID: "sys", Label: "系统根目录 /", Path: "/"})
}

func userHome(passwd, name string) string {
	b, _ := os.ReadFile(passwd)
	for _, line := range strings.Split(string(b), "\n") {
		if f := strings.Split(line, ":"); len(f) >= 7 && f[0] == name {
			return f[5]
		}
	}
	return ""
}

// wslDriveRoots are the PC's Windows drives as WSL mounts them (/mnt/c ...).
func wslDriveRoots() []entry.Root {
	b, _ := os.ReadFile("/proc/sys/kernel/osrelease")
	if !strings.Contains(strings.ToLower(string(b)), "microsoft") {
		return nil
	}
	m, _ := os.ReadFile("/proc/mounts")
	var out []entry.Root
	for _, line := range strings.Split(string(m), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || (f[2] != "9p" && f[2] != "drvfs" && f[2] != "virtiofs") {
			continue
		}
		mnt := f[1]
		if len(mnt) != 6 || !strings.HasPrefix(mnt, "/mnt/") || mnt[5] < 'a' || mnt[5] > 'z' {
			continue
		}
		out = append(out, entry.Root{ID: "win-" + mnt[5:], Label: "Windows " + strings.ToUpper(mnt[5:]) + ":", Path: mnt})
	}
	return out
}
