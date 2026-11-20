package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
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
	"aurora3/internal/update"
	"aurora3/internal/wire"
)

func TestLinuxProtectedClone(t *testing.T) {
	if path := os.Getenv("AURORA_PROTECTED_LINUX_HELPER"); path != "" {
		if err := run(path); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(9)
		}
		os.Exit(0)
	}
	t.Setenv("INVOCATION_ID", "")
	t.Setenv("CREDENTIALS_DIRECTORY", "")
	base := t.TempDir()
	source, dest, cred := filepath.Join(base, "legacy"), filepath.Join(base, "preview"), filepath.Join(base, "credentials")
	for _, path := range []string{source, cred} {
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	_, pin, err := wire.LoadOrCreateCert(source, "agent")
	if err != nil {
		t.Fatal(err)
	}
	const id = "0123456789abcdef01234567"
	if err := os.WriteFile(filepath.Join(source, "agent-id"), []byte(id+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	token := wire.NewToken()
	sourceConfig := filepath.Join(base, "legacy.json")
	targetConfig := filepath.Join(dest, "agent.json")
	opt := &entry.Config{Token: token, Listen: "127.0.0.1:0", StateDir: source, Roots: []entry.Root{{ID: "home", Path: base}}}
	if err := opt.Save(sourceConfig); err != nil {
		t.Fatal(err)
	}
	orig, err := os.ReadFile(sourceConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CREDENTIALS_DIRECTORY", cred)
	credential := filepath.Join(cred, "aurora-state-key")
	if err := os.WriteFile(credential, bytes.Repeat([]byte{5}, statecrypt.KeyBytes), 0o400); err != nil {
		t.Fatal(err)
	}
	args := []string{"--legacy-config", sourceConfig, "--dest", dest, "--instance", "verification", "--source-stopped"}
	if err := cloneProtectedPreview(args); err != nil {
		t.Fatal(err)
	}
	if err := cloneProtectedPreview(args); err == nil {
		t.Fatal("cloned over an existing target")
	}
	cfg, err := entry.LoadConfig(targetConfig)
	if err != nil || cfg.Token != token || cfg.Protection() == nil || cfg.Roots[0].Path == base {
		t.Fatal("invalid sealed config or non-isolated project root", err)
	}
	sealed, err := os.ReadFile(targetConfig)
	if err != nil || bytes.Contains(sealed, []byte(token)) || bytes.Contains(sealed, []byte(`"token"`)) {
		t.Fatal("configuration exposes the authentication token")
	}
	tampered := bytes.Replace(sealed, []byte(`"listen": "127.0.0.1:0"`), []byte(`"listen": "0.0.0.0:0"`), 1)
	if bytes.Equal(tampered, sealed) {
		t.Fatal("did not exercise public config authentication")
	}
	if err := os.WriteFile(targetConfig, tampered, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := entry.LoadConfig(targetConfig); err == nil {
		t.Fatal("changed public config was accepted")
	}
	if err := os.WriteFile(targetConfig, sealed, 0o600); err != nil {
		t.Fatal(err)
	}
	key, err := os.ReadFile(filepath.Join(dest, "agent.key"))
	if err != nil || !statecrypt.Protected(key) {
		t.Fatal("private key is not sealed")
	}
	runAgent := func(path, creds string, shouldStart bool) *wire.AgentInfo {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestLinuxProtectedClone$")
		cmd.Env = append(os.Environ(), "AURORA_PROTECTED_LINUX_HELPER="+path, "CREDENTIALS_DIRECTORY="+creds)
		if bin := os.Getenv("AURORA_LEGACY_LINUX_BINARY"); path == sourceConfig && bin != "" {
			cmd = exec.CommandContext(ctx, bin, "run", "--config", path)
			cmd.Env = append(os.Environ(), "CREDENTIALS_DIRECTORY="+creds)
		}
		if bin := os.Getenv("AURORA_PREVIEW_LINUX_BINARY"); path == targetConfig && bin != "" {
			cmd = exec.CommandContext(ctx, bin, "run", "--config", path)
			cmd.Env = append(os.Environ(), "CREDENTIALS_DIRECTORY="+creds)
		}
		stderr, err := cmd.StderrPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer func() {
			_ = cmd.Process.Signal(os.Interrupt)
			if cmd.ProcessState == nil {
				_ = cmd.Wait()
			}
		}()
		scanner := bufio.NewScanner(stderr)
		var diagnostics []string
		address := regexp.MustCompile(`listening on (127\.0\.0\.1:[0-9]+)`)
		for scanner.Scan() {
			diagnostics = append(diagnostics, scanner.Text())
			match := address.FindStringSubmatch(scanner.Text())
			if len(match) != 2 {
				continue
			}
			if !shouldStart {
				t.Fatal("missing credential allowed a listener")
			}
			who, err := install.DialAgent(ctx, match[1], pin, token)
			if err != nil || who.ID != id {
				t.Fatalf("identity or original token rejected: %v", err)
			}
			return who
		}
		err = cmd.Wait()
		if shouldStart || err == nil {
			t.Fatalf("unexpected process result: %v, %v", err, diagnostics)
		}
		return nil
	}
	checkSource := releaseChannel != update.ChannelPreview || os.Getenv("AURORA_LEGACY_LINUX_BINARY") != ""
	if checkSource {
		runAgent(sourceConfig, "", true)
	}
	for range 2 {
		who := runAgent(targetConfig, cred, true)
		for _, op := range who.Caps {
			if strings.HasPrefix(op, "agent.upgrade") || strings.HasPrefix(op, "session.") {
				t.Fatal("non-isolated operations available", op)
			}
		}
	}
	runAgent(targetConfig, "", false)
	if err := os.Chmod(credential, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credential, bytes.Repeat([]byte{7}, statecrypt.KeyBytes), 0o400); err != nil {
		t.Fatal(err)
	}
	runAgent(targetConfig, cred, false)
	if after, err := os.ReadFile(targetConfig); err != nil || !bytes.Equal(after, sealed) {
		t.Fatal("missing or wrong credentials altered protected config")
	}
	if checkSource {
		runAgent(sourceConfig, "", true)
	}
	after, err := os.ReadFile(sourceConfig)
	if err != nil || !bytes.Equal(orig, after) {
		t.Fatal("original config was modified")
	}
}
