//go:build linux

package terminal

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"aurora3/internal/wire"
)

// dirBundle reads the bundle from agent/internal/bundle (built by
// agent/tools/tmux). Tests skip when it is missing (a fresh checkout).
type dirBundle string

func (d dirBundle) ReadFile(name string) ([]byte, error) { return os.ReadFile(filepath.Join(string(d), name)) }

type rec struct{ events []string }

func (r *rec) Write(ev string, _ map[string]any) { r.events = append(r.events, ev) }

func newEnv(t *testing.T) *Env {
	t.Helper()
	b := dirBundle(os.Getenv("AURORA3_BUNDLE"))
	if b == "" {
		b = "../bundle"
	}
	if _, err := os.Stat(filepath.Join(string(b), "tmux.gz")); err != nil {
		t.Skip("no tmux bundle (agent/internal/bundle/tmux.gz)")
	}
	dir := t.TempDir()
	e := &Env{StateDir: dir, Roots: []Root{{ID: "tmp", Path: dir}}, Audit: &rec{}, Bundle: b,
		Socket: "aurora3-test-" + filepath.Base(dir), NoUnit: true}
	t.Cleanup(func() {
		_, _, _ = e.tmux(context.Background(), "kill-server")
	})
	return e
}

func TestBundledTmuxIsUsed(t *testing.T) {
	e := newEnv(t)
	info := e.Info()
	if info["bundled"] != true || !strings.HasPrefix(info["version"].(string), "tmux 3.") {
		t.Fatalf("%v", info)
	}
	if !strings.HasPrefix(filepath.Base(e.tmuxBin()), "tmux-") {
		t.Fatal(e.tmuxBin())
	}
	if e.terminfoDir() == "" || !isFile(e.confPath()) {
		t.Fatal("terminfo or tmux.conf missing")
	}
}

func TestCreateListCwdKill(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"bad name"}`)); wire.CodeOf(err) != wire.CodeBadRequest {
		t.Fatalf("bad name: %v", err)
	}
	if err := os.Mkdir(filepath.Join(e.Roots[0].Path, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"s1","root":"tmp","path":"sub"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"s1"}`)); err != nil {
		t.Fatal("create of an existing session is not an error:", err)
	}
	rows := e.Sessions(ctx)
	if len(rows) != 1 || rows[0].Name != "s1" {
		t.Fatalf("%+v", rows)
	}
	var cwd any
	for i := 0; i < 50; i++ {
		res, err := e.sessionCwd(ctx, json.RawMessage(`{"name":"s1"}`))
		if err == nil {
			cwd = res.(map[string]any)["cwd"]
			if strings.HasSuffix(cwd.(string), "/sub") {
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !strings.HasSuffix(cwd.(string), "/sub") {
		t.Fatalf("cwd %v", cwd)
	}
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"x","root":"tmp","path":"../.."}`)); err == nil {
		t.Fatal("path outside the root accepted")
	}
	if _, err := e.sessionKill(ctx, json.RawMessage(`{"name":"s1"}`)); err != nil {
		t.Fatal(err)
	}
	if len(e.Sessions(ctx)) != 0 {
		t.Fatal("session left")
	}
	if _, err := e.sessionKill(ctx, json.RawMessage(`{"name":"s1"}`)); wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("second kill: %v", err)
	}
	ev := e.Audit.(*rec).events
	if strings.Join(ev, ",") != "session.create,session.create,session.kill" {
		t.Fatalf("audit %v", ev)
	}
}

// client drives a terminal stream like the Dart client does. A reader
// goroutine collects everything, so the server never blocks on an unread
// pipe while the test writes (net.Pipe has no buffer).
type client struct {
	t    *testing.T
	e    *Env
	name string
	c    net.Conn
	mu   sync.Mutex
	out  bytes.Buffer
	ctl  []map[string]any
	gone chan struct{}
}

func newClient(t *testing.T, e *Env, name string, c net.Conn) *client {
	cl := &client{t: t, e: e, name: name, c: c, gone: make(chan struct{})}
	go func() {
		defer close(cl.gone)
		for {
			typ, p, err := wire.ReadFrame(c)
			if err != nil {
				return
			}
			cl.mu.Lock()
			if typ == wire.TypeData {
				cl.out.Write(p)
			} else {
				var m map[string]any
				_ = json.Unmarshal(p, &m)
				cl.ctl = append(cl.ctl, m)
			}
			cl.mu.Unlock()
		}
	}()
	return cl
}

func (c *client) send(typ byte, p []byte) {
	if err := wire.WriteFrame(c.c, typ, p); err != nil {
		c.t.Fatal(err)
	}
}

// waitScreen waits until the session's screen, as tmux renders it, contains
// want. The stream itself is tmux's redraw output (cursor moves, partial
// lines), so the screen is read with capture-pane. Output must also have
// reached the client.
func (c *client) waitScreen(want string, d time.Duration) error {
	deadline := time.Now().Add(d)
	var screen string
	for time.Now().Before(deadline) {
		// Screen plus scrollback: a resize redraws and may push lines up.
		out, errOut, err := c.e.tmux(context.Background(), "capture-pane", "-p", "-J", "-S", "-200", "-t", "="+c.name+":")
		screen = out
		if err != nil {
			screen = "capture-pane: " + err.Error() + " " + errOut
		}
		c.mu.Lock()
		got := c.out.Len()
		c.mu.Unlock()
		if err == nil && strings.Contains(out, want) && got > 0 {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("%q not on screen:\n%s", want, tail(strings.TrimRight(screen, " \n"), 600))
}

// screen is the session's current screen text.
func (c *client) screen() string {
	out, _, _ := c.e.tmux(context.Background(), "capture-pane", "-p", "-J", "-t", "="+c.name+":")
	return out
}

// waitControl waits for a control message of type typ.
func (c *client) waitControl(typ string, d time.Duration) (map[string]any, error) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		for _, m := range c.ctl {
			if m["type"] == typ {
				c.mu.Unlock()
				return m, nil
			}
		}
		c.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return nil, fmt.Errorf("no %q control message; got %v", typ, c.ctl)
}

func tail(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

func attachTo(t *testing.T, e *Env, name string) (*client, chan error) {
	t.Helper()
	a, b := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- e.terminal(context.Background(), b, json.RawMessage(`{"name":"`+name+`","cols":100,"rows":30}`)) }()
	_ = a.SetReadDeadline(time.Now().Add(10 * time.Second))
	typ, p, err := wire.ReadFrame(a)
	if err != nil || typ != wire.TypeJSON || !strings.Contains(string(p), `"ok":true`) {
		t.Fatalf("attach: %c %s %v", typ, p, err)
	}
	_ = a.SetReadDeadline(time.Time{})
	return newClient(t, e, name, a), done
}

func TestTerminalTypesAndKeepsTheSession(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"t1"}`)); err != nil {
		t.Fatal(err)
	}
	c, done := attachTo(t, e, "t1")
	c.send(wire.TypeData, []byte("echo AUR''ORA3-\xe4\xbd\xa0\xe5\xa5\xbd\r"))
	if err := c.waitScreen("AURORA3-你好", 10*time.Second); err != nil {
		t.Fatal("echo:", err)
	}
	// tmux keeps its status line on the top row, so the pane is one row
	// shorter than the window; the client's size reaches the pane.
	c.send(wire.TypeJSON, mustJSON(wire.TerminalControl{Type: "resize", Cols: 120, Rows: 40}))
	// The resize reaches the pane asynchronously; wait until tmux has it.
	size := ""
	for i := 0; i < 100; i++ {
		out, _, _ := e.tmux(ctx, "display-message", "-p", "-t", "=t1:", "#{pane_width}x#{pane_height}")
		if size = strings.TrimSpace(out); size == "120x39" {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if size != "120x39" {
		t.Fatalf("pane is %s after resize to 120x40 (one row is the status line)", size)
	}
	// The program in the pane sees it too (the kernel's tty size, via
	// SIGWINCH). Ask until it does: the first answer may predate the signal.
	ok := false
	for i := 0; i < 20 && !ok; i++ {
		c.send(wire.TypeData, []byte("echo SZ=$(stty size)=\r"))
		ok = c.waitScreen("SZ=39 120=", 500*time.Millisecond) == nil
	}
	if !ok {
		t.Fatal("the shell never saw the new size:", c.waitScreen("SZ=39 120=", 0))
	}
	c.send(wire.TypeJSON, mustJSON(wire.TerminalControl{Type: "ping", Code: 7}))
	if m, err := c.waitControl("pong", 5*time.Second); err != nil || m["code"] != float64(7) {
		t.Fatalf("pong: %v %v", m, err)
	}
	// The client closing the stream detaches; the session stays (D-18).
	c.c.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if len(e.Sessions(ctx)) != 1 {
		t.Fatal("session ended with the window")
	}
	// Attach again: the session is the same one.
	c2, done2 := attachTo(t, e, "t1")
	c2.send(wire.TypeData, []byte("echo sec''ond\r"))
	if err := c2.waitScreen("second", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	// The shell exiting ends the session: "exit".
	c2.send(wire.TypeData, []byte("exit\r"))
	if _, err := c2.waitControl("exit", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	<-done2
	if _, err := attachTo2(e, "t1"); wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("attach to an ended session: %v", err)
	}
}

func attachTo2(e *Env, name string) (any, error) {
	a, b := net.Pipe()
	defer a.Close()
	go io.Copy(io.Discard, a)
	return nil, e.terminal(context.Background(), b, json.RawMessage(`{"name":"`+name+`"}`))
}

func TestSwitchingOffDisconnectsButKeepsSessions(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"k1"}`)); err != nil {
		t.Fatal(err)
	}
	c, done := attachTo(t, e, "k1")
	time.Sleep(200 * time.Millisecond) // registered as attached
	svc{e}.Switched(false)
	m, err := c.waitControl("closed", 5*time.Second)
	if err != nil || !strings.Contains(m["reason"].(string), "关闭") {
		t.Fatalf("%v %v", m, err)
	}
	<-done
	if len(e.Sessions(ctx)) != 1 {
		t.Fatal("D-51: the session must keep running")
	}
	// session.kill works while off (D-52): it is not one of the service's ops.
	for _, op := range (svc{e}).Operations() {
		if op.Name == "session.kill" {
			t.Fatal("session.kill must belong to the entry")
		}
	}
	if _, err := e.KillOp()(ctx, json.RawMessage(`{"name":"k1"}`)); err != nil {
		t.Fatal(err)
	}
}

func TestKillEndsProcessesThatIgnoreHangup(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"h1"}`)); err != nil {
		t.Fatal(err)
	}
	c, done := attachTo(t, e, "h1")
	// A background job that ignores SIGHUP, as nohup-less long jobs do.
	// The output marker is split in the typed command, so only the shell's
	// output (not the echo of the command line) matches it.
	c.send(wire.TypeData, []byte("(trap '' HUP; exec sleep 613) & echo PI''D=$!=END\r"))
	if err := c.waitScreen("=END", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	screen := c.screen()
	i := strings.LastIndex(screen, "PID=")
	pid := strings.SplitN(screen[i+4:], "=", 2)[0]
	c.c.Close()
	<-done
	if _, err := os.Stat("/proc/" + pid); err != nil {
		t.Fatalf("background job %s not running: %v", pid, err)
	}
	res, err := e.sessionKill(ctx, json.RawMessage(`{"name":"h1"}`))
	if err != nil {
		t.Fatal(err)
	}
	if res.(map[string]any)["forced"].(int) < 1 {
		t.Fatalf("nothing forced: %v", res)
	}
	if b, err := os.ReadFile("/proc/" + pid + "/cmdline"); err == nil && strings.HasPrefix(string(b), "sleep\x00613") {
		t.Fatalf("pid %s survived the kill", pid)
	}
}
