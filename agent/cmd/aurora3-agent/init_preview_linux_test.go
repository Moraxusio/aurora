package main

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/install"
	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

func TestPublicPreviewExecutable(t *testing.T) {
	bin := os.Getenv("AURORA_PREVIEW_LINUX_BINARY")
	if bin == "" {
		t.Skip("configure AURORA_PREVIEW_LINUX_BINARY for signed ELF verification")
	}
	t.Setenv("INVOCATION_ID", "")
	base := t.TempDir()
	creds, dest := filepath.Join(base, "credentials"), filepath.Join(base, "preview")
	if err := os.Mkdir(creds, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(creds, "aurora-state-key"), bytes.Repeat([]byte{27}, 32), 0o400); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	command := func(c string, args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, bin, args...)
		cmd.Env = append(os.Environ(), "CREDENTIALS_DIRECTORY="+c)
		return cmd
	}
	token := wire.NewToken()
	initArgs := []string{"init-protected-preview", "--dest", dest, "--instance", "previewtest"}
	init := func(c string) error {
		cmd := command(c, initArgs...)
		cmd.Stdin = strings.NewReader(token + "\n")
		return cmd.Run()
	}
	if init("") == nil {
		t.Fatal("initialization accepted missing credential")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("failed initialization left a destination")
	}
	if err := init(creds); err != nil {
		t.Fatal(err)
	}
	if init(creds) == nil {
		t.Fatal("initialization accepted an existing destination")
	}
	path := filepath.Join(dest, "agent.json")
	original, err := os.ReadFile(path)
	if err != nil || bytes.Contains(original, []byte(token)) {
		t.Fatal("token was not sealed", err)
	}
	key, err := os.ReadFile(filepath.Join(dest, "agent.key"))
	if err != nil || !statecrypt.Protected(key) {
		t.Fatal("new identity was not sealed", err)
	}
	for _, args := range [][]string{{"install"}, {"uninstall"}, {"upgrade-worker"}, {"run"}} {
		if err := command(creds, args...).Run(); err == nil {
			t.Fatalf("preview accepted a production command %q", args)
		}
	}
	legacy := &entry.Config{Listen: "127.0.0.1:0", Token: token, StateDir: filepath.Join(base, "legacy")}
	legacyPath := filepath.Join(base, "legacy.json")
	if err := legacy.Save(legacyPath); err != nil {
		t.Fatal(err)
	}
	if err := command("", "run", "--config", legacyPath).Run(); err == nil {
		t.Fatal("preview started on legacy state")
	}
	if _, err := os.Stat(legacy.StateDir); !os.IsNotExist(err) {
		t.Fatal("preview touched legacy state")
	}
	if err := command("", "run", "--config", path).Run(); err == nil {
		t.Fatal("preview ran without key")
	}
	version, err := command("", "version").Output()
	if err != nil {
		t.Fatal(err)
	}
	root, err := statecrypt.OpenStateDir(dest)
	if err != nil {
		t.Fatal(err)
	}
	pin, id, err := entry.ValidatePreviewPairing(root)
	root.Close()
	if err != nil {
		t.Fatal(err)
	}
	address := regexp.MustCompile(`listening on (127\.0\.0\.1:[0-9]+)`)
	for range 2 {
		cmd := command(creds, "run", "--config", path)
		logs, err := cmd.StderrPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if cmd.ProcessState == nil {
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
			}
		})
		port := ""
		for scanner := bufio.NewScanner(logs); scanner.Scan(); {
			if match := address.FindStringSubmatch(scanner.Text()); len(match) == 2 {
				port = match[1]
				break
			}
		}
		if port == "" {
			t.Fatal("signed preview did not start a loopback listener")
		}
		info, err := install.DialAgent(ctx, port, pin, token)
		if err != nil || info.ID != id || info.Version != strings.TrimSpace(string(version)) {
			t.Fatal("signed preview TLS/ID/version check failed", err)
		}
		for _, capability := range info.Caps {
			if strings.HasPrefix(capability, "agent.upgrade") || strings.HasPrefix(capability, "session.") {
				t.Fatal("preview exposed a disabled capability", capability)
			}
		}
		_ = cmd.Process.Signal(os.Interrupt)
		if err := cmd.Wait(); err != nil {
			t.Fatal(err)
		}
	}
	if b, err := os.ReadFile(path); err != nil || !bytes.Equal(b, original) {
		t.Fatal("restart modified protected configuration", err)
	}
}
