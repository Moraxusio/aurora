//go:build linux

package terminal

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

const testProxyPass = "pw-PROXY-secret-9f3a1c77"

func proxyEnvFor(e *Env) {
	e.Proxy = func() (map[string]string, error) {
		return map[string]string{
			"HTTP_PROXY":  "http://aurora:" + testProxyPass + "@127.0.0.1:23456",
			"HTTPS_PROXY": "http://aurora:" + testProxyPass + "@127.0.0.1:23456",
			"ALL_PROXY":   "socks5h://aurora:" + testProxyPass + "@127.0.0.1:23456",
		}, nil
	}
}

// printEnv runs a command in a session and returns what it printed. The
// session's own shell does the work, so what comes back is what a program
// started there would see.
func runIn(t *testing.T, e *Env, name, cmd string) string {
	t.Helper()
	marker := "END" + strings.ToUpper(name)
	if _, _, err := e.tmux(context.Background(), "send-keys", "-t", "="+name+":", cmd+"; echo "+marker, "Enter"); err != nil {
		t.Fatal(err)
	}
	var screen string
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		out, _, _ := e.tmux(context.Background(), "capture-pane", "-p", "-J", "-S", "-200", "-t", "="+name+":")
		screen = out
		// the marker is echoed after the command: it appears twice once the
		// command line itself and its output are both on the screen
		if strings.Count(out, marker) >= 2 {
			return out
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("no output from %q; screen:\n%s", cmd, screen)
	return ""
}

func TestSessionWithProxyGetsTheVariablesAndNothingLeaks(t *testing.T) {
	e := newEnv(t)
	proxyEnvFor(e)
	ctx := context.Background()
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"viaproxy","proxy":true}`)); err != nil {
		t.Fatal(err)
	}
	out := runIn(t, e, "viaproxy", `echo "HP=$HTTP_PROXY"; echo "AP=$ALL_PROXY"`)
	if !strings.Contains(out, "HP=http://aurora:"+testProxyPass+"@127.0.0.1:23456") {
		t.Fatalf("the session has no HTTP_PROXY:\n%s", out)
	}
	if !strings.Contains(out, "AP=socks5h://") {
		t.Fatalf("the session has no ALL_PROXY:\n%s", out)
	}

	// 1. the password is not in tmux's own command line, where any local user
	// can read it
	procs, _ := exec.Command("ps", "-eo", "args").Output()
	if strings.Contains(string(procs), testProxyPass) {
		t.Fatalf("the proxy password is in a process command line:\n%s", grepLines(string(procs), testProxyPass))
	}
	// 2. the environment file was removed once the session read it
	dir := filepath.Join(e.StateDir, "session-env")
	left, _ := os.ReadDir(dir)
	if len(left) != 0 {
		t.Fatalf("the environment file is still on disk: %v", left)
	}
	// 3. the folder only the agent's user can enter
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("session-env folder: %v %v", fi, err)
	}
	// 4. the audit line names no secret
	rec, _ := e.Audit.(*rec)
	for _, ev := range rec.events {
		if strings.Contains(ev, testProxyPass) {
			t.Fatalf("the audit log has the password: %v", rec.events)
		}
	}
}

func grepLines(s, sub string) string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if strings.Contains(l, sub) {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}

func TestSessionWithoutProxyHasNone(t *testing.T) {
	e := newEnv(t)
	proxyEnvFor(e) // the proxy exists, but this session did not ask for it
	if _, err := e.sessionCreate(context.Background(), json.RawMessage(`{"name":"plain"}`)); err != nil {
		t.Fatal(err)
	}
	// The machine may have a proxy of its own (this test host does, from a
	// profile.d file): what must be absent is Aurora's, which is the one that
	// carries the credentials of the agent's local proxy.
	out := runIn(t, e, "plain", `echo "HP=[${HTTP_PROXY:-none}]"; echo "AP=[${ALL_PROXY:-none}]"`)
	if strings.Contains(out, testProxyPass) || strings.Contains(out, "127.0.0.1:23456") || strings.Contains(out, "socks5h://aurora") {
		t.Fatalf("a session that did not ask for the proxy has the agent's:\n%s", out)
	}
}

// D-49: asking for a proxy that cannot be had is an error, and no session is
// made, so the user is never left in a terminal they believe is proxied.
func TestProxySessionRefusedWhenNoProxyIsAvailable(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	// a. this agent has no proxy service at all
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"a","proxy":true}`)); wire.CodeOf(err) != wire.CodeUnavailable {
		t.Fatalf("no service: error %v", err)
	}
	// b. the service says why (off, or no node chosen): its words reach the user
	e.Proxy = func() (map[string]string, error) { return nil, errors.New("还没有选择代理节点") }
	_, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"b","proxy":true}`))
	if wire.CodeOf(err) != wire.CodeUnavailable || err == nil || !strings.Contains(err.Error(), "节点") {
		t.Fatalf("service reason: error %v", err)
	}
	for _, n := range []string{"a", "b"} {
		if e.exists(ctx, n) {
			t.Fatalf("session %q was created although its proxy was refused", n)
		}
	}
	// the same name without a proxy still works afterwards
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"a"}`)); err != nil {
		t.Fatalf("a plain session after a refusal: %v", err)
	}
}

// D-48: the proxy is decided at creation. Asking again for a session that is
// already there does not change it, and the reply says so.
func TestProxyIsNotAddedToAnExistingSession(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"old"}`)); err != nil {
		t.Fatal(err)
	}
	proxyEnvFor(e)
	res, err := e.sessionCreate(ctx, json.RawMessage(`{"name":"old","proxy":true}`))
	if err != nil {
		t.Fatal(err)
	}
	m := res.(map[string]any)
	if m["existed"] != true || m["proxy"] != false {
		t.Fatalf("reply %v: it should say the session existed and has no proxy", m)
	}
	out := runIn(t, e, "old", `echo "HP=[${HTTP_PROXY:-none}]"`)
	if strings.Contains(out, testProxyPass) || strings.Contains(out, "127.0.0.1:23456") {
		t.Fatalf("an existing session was changed:\n%s", out)
	}
}

// A variable name that is not a plain identifier is dropped: nothing in the
// map can carry shell syntax into the file.
func TestEnvFileRefusesOddNames(t *testing.T) {
	e := newEnv(t)
	path, err := e.writeSessionEnv("x", map[string]string{
		"GOOD":        "a'b\"c$(touch /tmp/pwned)",
		"bad name":    "1",
		"A;rm -rf /":  "1",
		"1LEADING":    "1",
		"also_good_2": "v",
	})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	s := string(b)
	for _, bad := range []string{"bad name", "rm -rf", "1LEADING"} {
		if strings.Contains(s, bad) {
			t.Fatalf("file carries %q:\n%s", bad, s)
		}
	}
	if !strings.Contains(s, "export GOOD=") || !strings.Contains(s, "export also_good_2=") {
		t.Fatalf("good names missing:\n%s", s)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode().Perm())
	}
	// and a value full of quotes comes back exactly, evaluated by a real shell
	out, err := exec.Command("sh", "-c", ". "+shellQuote(path)+`; printf %s "$GOOD"`).Output()
	if err != nil || string(out) != `a'b"c$(touch /tmp/pwned)` {
		t.Fatalf("value did not round-trip: %q %v", out, err)
	}
	if _, err := os.Stat("/tmp/pwned"); err == nil {
		os.Remove("/tmp/pwned")
		t.Fatal("a command in a value was run")
	}
}
