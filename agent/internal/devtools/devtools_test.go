package devtools

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

func TestDevelopmentChild(t *testing.T) {
	mode := os.Getenv("AURORA_DEV_CHILD")
	if mode == "" {
		return
	}
	switch mode {
	case "protocol":
		r := bufio.NewReader(os.Stdin)
		for {
			data, err := readMessage(r)
			if err != nil {
				os.Exit(0)
			}
			var msg map[string]any
			if json.Unmarshal(data, &msg) != nil {
				os.Exit(3)
			}
			if msg["method"] == "exit" {
				os.Exit(0)
			}
			out, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": msg["id"], "result": msg["params"]})
			if writeMessage(os.Stdout, out) != nil {
				os.Exit(4)
			}
		}
	case "task":
		fmt.Fprintln(os.Stdout, "中文/task.dart:3:2: test failure")
		fmt.Fprintln(os.Stderr, "stderr output")
		os.Exit(7)
	case "descendant":
		cmd := exec.Command(os.Args[0], "-test.run=^TestDevelopmentChild$")
		cmd.Env = append(os.Environ(), "AURORA_DEV_CHILD=hang")
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if cmd.Start() != nil {
			os.Exit(3)
		}
		fmt.Fprintln(os.Stdout, "spawned descendant")
		os.Exit(0)
	case "hang":
		for {
			time.Sleep(time.Hour)
		}
	}
	os.Exit(0)
}

func developmentFixture(t *testing.T) (*Env, string) {
	t.Helper()
	work := t.TempDir()
	e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
	cfg := Config{Version: 1, LanguageServers: []LanguageServer{{
		Program: Program{ID: "fixture", Command: []string{os.Args[0], "-test.run=^TestDevelopmentChild$"},
			Env: map[string]string{"AURORA_DEV_CHILD": "protocol"}}, Languages: []string{"dart"},
	}}, Tasks: []Task{
		{Program: Program{ID: "test", Command: []string{os.Args[0], "-test.run=^TestDevelopmentChild$"}, Env: map[string]string{"AURORA_DEV_CHILD": "task"}}, Group: "test"},
		{Program: Program{ID: "tree", Command: []string{os.Args[0], "-test.run=^TestDevelopmentChild$"}, Env: map[string]string{"AURORA_DEV_CHILD": "descendant"}}},
	}}
	data, _ := json.Marshal(cfg)
	if err := os.MkdirAll(filepath.Join(work, ".aurora"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, filepath.FromSlash(configPath)), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return e, work
}

func TestLanguageBridgeUsesRealStdioAndCancelsOnStreamClose(t *testing.T) {
	e, _ := developmentFixture(t)
	server, client := net.Pipe()
	defer client.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	done := make(chan error, 1)
	go func() {
		done <- e.languageServer(context.Background(), server, json.RawMessage(`{"root":"work","path":"/","id":"fixture"}`))
	}()
	var ack wire.Response
	if err := wire.ReadJSON(client, &ack); err != nil || !ack.OK {
		t.Fatalf("ack: %+v %v", ack, err)
	}
	message := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"name":"中文"}}`)
	if err := wire.WriteFrame(client, wire.TypeData, message); err != nil {
		t.Fatal(err)
	}
	typ, payload, err := wire.ReadFrame(client)
	if err != nil || typ != wire.TypeData || !bytes.Contains(payload, []byte("中文")) {
		t.Fatalf("reply: %c %s %v", typ, payload, err)
	}
	client.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("LSP process did not terminate on stream cancellation")
	}
	if e.running != 0 {
		t.Fatal("process permit leaked")
	}
}

func TestTasksReportExitCodeAndTerminateDescendantsBeforeClosingOutput(t *testing.T) {
	for _, id := range []string{"test", "tree"} {
		t.Run(id, func(t *testing.T) {
			e, _ := developmentFixture(t)
			server, client := net.Pipe()
			defer client.Close()
			client.SetDeadline(time.Now().Add(5 * time.Second))
			done := make(chan error, 1)
			args, _ := json.Marshal(scopeArgs{Root: "work", Path: "/", ID: id})
			go func() { done <- e.runTask(context.Background(), server, args) }()
			var text strings.Builder
			code := -100
			for {
				var event map[string]any
				if err := wire.ReadJSON(client, &event); err != nil {
					t.Fatal(err)
				}
				if value, ok := event["text"].(string); ok {
					text.WriteString(value)
				}
				if event["type"] == "complete" {
					code = int(event["code"].(float64))
					break
				}
			}
			if id == "test" && (code != 7 || !strings.Contains(text.String(), "中文/task.dart") || !strings.Contains(text.String(), "stderr output")) {
				t.Fatalf("task output: code=%d text=%q", code, text.String())
			}
			if id == "tree" && (code != 0 || !strings.Contains(text.String(), "spawned descendant")) {
				t.Fatalf("tree: %d %q", code, text.String())
			}
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("task leaked")
			}
		})
	}
}

func TestProtocolFramesAreBoundedAndPreserveUnicode(t *testing.T) {
	for _, input := range []string{
		"Content-Length: 1048576\r\n\r\n",
		"Content-Length: 3\r\nContent-Length: 3\r\n\r\n{}\n",
		"Content-Length: -1\r\n\r\n",
		"Content-Type: application/json\r\n\r\n{}",
		"Content-Length: 10\r\n\r\n{}",
	} {
		if _, err := readMessage(bufio.NewReader(strings.NewReader(input))); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
	var out bytes.Buffer
	data := []byte(`{"text":"你好"}`)
	if err := writeMessage(&out, data); err != nil {
		t.Fatal(err)
	}
	read, err := readMessage(bufio.NewReader(&out))
	if err != nil || !bytes.Equal(read, data) {
		t.Fatalf("unicode: %s %v", read, err)
	}
}

func TestConfigurationUsesVersionCheckedTransactionAndRejectsTaskCycles(t *testing.T) {
	e, work := developmentFixture(t)
	cfg, state, err := readConfig(work)
	if err != nil {
		t.Fatal(err)
	}
	args, _ := json.Marshal(scopeArgs{Root: "work", Path: "/", IfMatch: configTag(state), Config: &cfg})
	if _, err := e.configure(context.Background(), args); err != nil {
		t.Fatal(err)
	}
	if _, err := e.configure(context.Background(), args); wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("stale configuration was accepted: %v", err)
	}
	cfg.Tasks[0].DependsOn = []string{"tree"}
	cfg.Tasks[1].DependsOn = []string{"test"}
	if err := cfg.validate(); err == nil {
		t.Fatal("dependency cycle accepted")
	}
}

func TestProcessBudgetAndStartupFailuresReleasePermit(t *testing.T) {
	e, work := developmentFixture(t)
	var release []func()
	for range maxProcesses {
		r, err := e.acquire()
		if err != nil {
			t.Fatal(err)
		}
		release = append(release, r)
	}
	if _, err := e.acquire(); err == nil {
		t.Fatal("process budget exceeded")
	}
	for _, r := range release {
		r()
	}
	cfg, _, _ := readConfig(work)
	cfg.LanguageServers[0].Command = []string{filepath.Join(work, "missing-program")}
	raw, _ := json.Marshal(cfg)
	if err := os.WriteFile(filepath.Join(work, filepath.FromSlash(configPath)), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	server, client := net.Pipe()
	defer client.Close()
	defer server.Close()
	if err := e.languageServer(context.Background(), server, json.RawMessage(`{"root":"work","path":"/","id":"fixture"}`)); err == nil {
		t.Fatal("missing executable accepted")
	}
	if e.running != 0 {
		t.Fatal("failed start leaked permit")
	}
}

func TestTextOutputChunksDoNotSplitUTF8(t *testing.T) {
	input := strings.Repeat("中文", 5000)
	var out strings.Builder
	err := readTextChunks(strings.NewReader(input), func(s string) error { out.WriteString(s); return nil })
	if err != io.EOF || out.String() != input {
		t.Fatal("UTF-8 output changed")
	}
}
