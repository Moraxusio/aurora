package winlocal

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCommandEnvironmentAndExitCode(t *testing.T) {
	var out bytes.Buffer
	p, err := StartCommand([]string{Shell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "[Console]::WriteLine($env:AURORA_FIXTURE); exit 7"}, t.TempDir(), Merge(os.Environ(), map[string]string{"AURORA_FIXTURE": "synthetic-proxy"}), &out)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	err = p.Wait()
	e, ok := err.(*ExitError)
	if !ok || e.ExitCode() != 7 {
		t.Fatalf("exit: %v", err)
	}
	if !strings.Contains(out.String(), "synthetic-proxy") {
		t.Fatalf("output: %q", out.String())
	}
}
func TestCommandKillIncludesChildren(t *testing.T) {
	dir := t.TempDir()
	heartbeat := filepath.Join(dir, "heartbeat.txt")
	script := filepath.Join(dir, "child.ps1")
	if err := os.WriteFile(script, []byte("while ($true) { Add-Content -LiteralPath '"+heartbeat+"' -Value 'tick'; Start-Sleep -Milliseconds 50 }"), 0600); err != nil {
		t.Fatal(err)
	}
	p, err := StartCommand([]string{Shell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "& '" + Shell() + "' -NoProfile -File '" + script + "'"}, dir, os.Environ(), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if fi, err := os.Stat(heartbeat); err == nil && fi.Size() > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("child never started")
		}
		time.Sleep(25 * time.Millisecond)
	}
	p.Kill(true)
	_ = p.Wait()
	fi, err := os.Stat(heartbeat)
	if err != nil {
		t.Fatal(err)
	}
	size := fi.Size()
	time.Sleep(200 * time.Millisecond)
	fi, err = os.Stat(heartbeat)
	if err != nil || fi.Size() != size {
		t.Fatal("child survived job cancellation")
	}
}
func TestConsolePowerShellAndResize(t *testing.T) {
	dir := t.TempDir()
	c, err := StartConsole(dir, Merge(os.Environ(), map[string]string{"AURORA_CONPTY_FIXTURE": "conpty-synthetic"}), 100, 30, "-NoProfile")
	if err != nil {
		t.Fatal(err)
	}
	output := make(chan string, 1)
	go func() {
		var all bytes.Buffer
		b := make([]byte, 4096)
		for {
			n, err := c.Output.Read(b)
			if n > 0 {
				all.Write(b[:n])
				if bytes.Contains(b[:n], []byte("\x1b[6n")) {
					_, _ = c.Input.Write([]byte("\x1b[1;1R"))
				}
			}
			if err != nil {
				break
			}
		}
		output <- all.String()
	}()
	defer c.Close()
	if err = c.Resize(120, 40); err != nil {
		t.Fatal(err)
	}
	_, err = c.Input.Write([]byte("[Console]::WriteLine($env:AURORA_CONPTY_FIXTURE); exit\r"))
	if err != nil {
		t.Fatal(err)
	}
	select {
	case text := <-output:
		if !strings.Contains(text, "conpty-synthetic") {
			t.Fatalf("console output: %q", text)
		}
	case <-time.After(15 * time.Second):
		c.Close()
		t.Fatal("console did not finish")
	}
}
func TestMergeProxyCaseInsensitive(t *testing.T) {
	env := Merge([]string{"Path=fixture", "https_proxy=old"}, map[string]string{"HTTPS_PROXY": "http://127.0.0.1:12345"})
	if len(env) != 2 || strings.Contains(strings.Join(env, "\n"), "old") {
		t.Fatal(env)
	}
}
