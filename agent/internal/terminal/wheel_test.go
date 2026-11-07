//go:build linux

package terminal

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

// The mouse wheel must reach what is running in the pane, through the real
// tmux Aurora ships, with the configuration the agent writes. Three programs,
// the three cases a wheel meets:
//
//	less      full screen, no mouse reporting: tmux turns a wheel into arrow
//	          keys for it (alternate-screen + no mouse flag) and less scrolls.
//	a mouse   a program that asks for mouse events (DECSET 1000/1006), as vim
//	  program and opencode do: tmux must pass the wheel through, as the
//	          escape sequence the program asked for.
//	a shell   a plain pane: the wheel scrolls tmux's own history.
//
// A wheel event is sent the way the client does (SGR mouse report on the
// terminal stream), so a break anywhere between the client's bytes and the
// program shows here.

const sgrWheelUp = "\x1b[<64;10;5M"   // wheel up at column 10, row 5
const sgrWheelDown = "\x1b[<65;10;5M" // wheel down

func needs(t *testing.T, prog string) {
	t.Helper()
	if _, err := exec.LookPath(prog); err != nil {
		t.Skipf("no %s on this machine", prog)
	}
}

func TestWheelScrollsLess(t *testing.T) {
	needs(t, "less")
	e := newEnv(t)
	if _, err := e.sessionCreate(context.Background(), json.RawMessage(`{"name":"w1"}`)); err != nil {
		t.Fatal(err)
	}
	c, _ := attachTo(t, e, "w1")
	// 200 numbered lines in less, which starts at line 1
	c.send(wire.TypeData, []byte("seq 1 200 | less\r"))
	if err := c.waitScreen("(END)", 0); err == nil {
		t.Fatal("less showed the end at once")
	}
	if err := c.waitScreen("\n1\n", 10*time.Second); err != nil && !strings.Contains(c.screen(), "\n2\n") {
		t.Fatal("less did not start:", err)
	}
	first := func() string { // the first line less shows on screen (below tmux's status line)
		lines := strings.Split(strings.TrimRight(c.screen(), "\n"), "\n")
		for _, l := range lines {
			if s := strings.TrimSpace(l); s != "" && isNumber(s) {
				return s
			}
		}
		return ""
	}
	if first() != "1" {
		t.Fatalf("less starts at line %q, want 1\n%s", first(), c.screen())
	}
	// ten wheel clicks down
	for i := 0; i < 10; i++ {
		c.send(wire.TypeData, []byte(sgrWheelDown))
		time.Sleep(30 * time.Millisecond)
	}
	waitFor(t, "less scrolled down", func() bool { return first() != "1" && first() != "" }, func() string { return c.screen() })
	down := first()
	// and back up
	for i := 0; i < 10; i++ {
		c.send(wire.TypeData, []byte(sgrWheelUp))
		time.Sleep(30 * time.Millisecond)
	}
	waitFor(t, "less scrolled back up", func() bool { return first() == "1" }, func() string { return c.screen() })
	t.Logf("10 wheel clicks moved less from line 1 to line %s and back", down)
	c.send(wire.TypeData, []byte("q"))
}

// A program that wants mouse events gets the wheel as the escape sequence it
// asked for, untouched by tmux.
func TestWheelReachesAMouseProgram(t *testing.T) {
	needs(t, "python3")
	e := newEnv(t)
	if _, err := e.sessionCreate(context.Background(), json.RawMessage(`{"name":"w2"}`)); err != nil {
		t.Fatal(err)
	}
	c, _ := attachTo(t, e, "w2")
	// A script that switches on mouse reporting (1000 = clicks and wheel,
	// 1006 = SGR format), puts the terminal in raw mode, and prints what it
	// receives in hex. Written to a file: a long one-liner would not survive
	// the shell. The markers are split in the source ('REA'+'DY'), so the echo
	// of the command line cannot be mistaken for the program's own output.
	script := e.StateDir + "/mouse.py"
	src := "import os, select, sys, termios, tty\n" +
		"fd = 0\n" +
		"old = termios.tcgetattr(fd)\n" +
		"tty.setraw(fd)\n" +
		"sys.stdout.write('\\x1b[?1000h\\x1b[?1006h' + 'REA' + 'DY\\r\\n')\n" +
		"sys.stdout.flush()\n" +
		"data = b''\n" +
		"while len(data) < 24:\n" +
		"    r, _, _ = select.select([fd], [], [], 5)\n" +
		"    if not r:\n" +
		"        break\n" +
		"    data += os.read(fd, 64)\n" +
		"sys.stdout.write('\\x1b[?1000l\\x1b[?1006l')\n" +
		"termios.tcsetattr(fd, termios.TCSADRAIN, old)\n" +
		"print('GO' + 'T:' + data.hex())\n"
	if err := os.WriteFile(script, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	c.send(wire.TypeData, []byte("python3 "+script+"\r"))
	if err := c.waitScreen("READY", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	// a wheel up and a wheel down, as the client sends them
	c.send(wire.TypeData, []byte(sgrWheelUp))
	time.Sleep(100 * time.Millisecond)
	c.send(wire.TypeData, []byte(sgrWheelDown))
	waitFor(t, "the program got both wheel events", func() bool { return strings.Contains(c.screen(), "GOT:") }, func() string { return c.screen() })
	got := c.screen()
	i := strings.Index(got, "GOT:")
	hex := strings.Fields(got[i+4:])[0]
	// tmux re-encodes the report for the pane (button 64/65, the position in the pane)
	for _, want := range []string{"3c3634", "3c3635"} { // "<64", "<65"
		if !strings.Contains(hex, want) {
			t.Fatalf("the program did not receive %q; it got %s", want, hex)
		}
	}
}

// A plain shell: the wheel scrolls tmux's history, and scrolling back to the
// bottom leaves it again (copy-mode -e), so typing goes to the shell.
func TestWheelScrollsTheHistoryOfAShell(t *testing.T) {
	e := newEnv(t)
	if _, err := e.sessionCreate(context.Background(), json.RawMessage(`{"name":"w3"}`)); err != nil {
		t.Fatal(err)
	}
	c, _ := attachTo(t, e, "w3")
	c.send(wire.TypeData, []byte("seq 1 300; echo HIST''ORY-END\r"))
	if err := c.waitScreen("HISTORY-END", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	state := func() string {
		out, _, _ := e.tmux(context.Background(), "display-message", "-p", "-t", "="+c.name+":", "#{pane_in_mode} #{scroll_position}")
		return strings.TrimSpace(out)
	}
	if got := state(); got != "0 " && got != "0" {
		t.Fatalf("before scrolling the pane is not in a mode: %q", got)
	}
	for i := 0; i < 6; i++ {
		c.send(wire.TypeData, []byte(sgrWheelUp))
		time.Sleep(30 * time.Millisecond)
	}
	waitFor(t, "the pane is in copy mode, scrolled up", func() bool {
		f := strings.Fields(state())
		return len(f) == 2 && f[0] == "1" && f[1] != "0"
	}, func() string { return "state: " + state() + "\n" + c.screen() })
	// the wheel down brings it back to the bottom and out of copy mode
	for i := 0; i < 40; i++ {
		c.send(wire.TypeData, []byte(sgrWheelDown))
		time.Sleep(20 * time.Millisecond)
	}
	waitFor(t, "back at the bottom, out of copy mode", func() bool { return strings.HasPrefix(state(), "0") },
		func() string { return "state: " + state() + "\n" + c.screen() })
}

func isNumber(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func waitFor(t *testing.T, what string, ok func() bool, show func() string) {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(50 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatalf("did not happen within 10 s: %s\nscreen:\n%s", what, show())
}

var _ = wire.TypeData
