package devtools

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"aurora3/internal/wire"
)

// Opt-in real SDK acceptance, separate from deterministic subprocess fixtures.
// AURORA_TEST_DART points to a local SDK executable; no account or network needed.
func TestRealDartLanguageAndDebugAdapters(t *testing.T) {
	dart := os.Getenv("AURORA_TEST_DART")
	if dart == "" {
		t.Skip("set AURORA_TEST_DART to exercise the real Dart SDK")
	}
	for _, debug := range []bool{false, true} {
		name := "lsp"
		if debug {
			name = "dap"
		}
		t.Run(name, func(t *testing.T) {
			work := t.TempDir()
			program := filepath.Join(work, "main.dart")
			text := "void main() {\n  final answer = 42;\n  print(answer);\n}\n"
			if err := os.WriteFile(program, []byte(text), 0o600); err != nil {
				t.Fatal(err)
			}
			cfg := Config{Version: 1,
				LanguageServers: []LanguageServer{{Program: Program{ID: "dart", Command: []string{dart, "language-server", "--protocol=lsp"}}, Languages: []string{"dart"}}},
				Debug:           []DebugAdapter{{Program: Program{ID: "dart", Command: []string{dart, "debug_adapter"}}, Request: "launch"}},
			}
			if err := os.MkdirAll(filepath.Join(work, ".aurora"), 0o700); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(cfg)
			if err := os.WriteFile(filepath.Join(work, configPath), data, 0o600); err != nil {
				t.Fatal(err)
			}
			e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: work}}}
			server, client := net.Pipe()
			client.SetDeadline(time.Now().Add(90 * time.Second))
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() {
				done <- e.protocol(ctx, server, json.RawMessage(`{"root":"work","path":"/","id":"dart"}`), debug)
			}()
			defer func() {
				cancel()
				client.Close()
				select {
				case err := <-done:
					if err != nil {
						t.Error(err)
					}
				case <-time.After(5 * time.Second):
					t.Error("adapter process leaked")
				}
			}()
			var ack wire.Response
			if err := wire.ReadJSON(client, &ack); err != nil || !ack.OK {
				t.Fatalf("ack %+v %v", ack, err)
			}
			send := func(message map[string]any) {
				t.Helper()
				payload, _ := json.Marshal(message)
				if err := wire.WriteFrame(client, wire.TypeData, payload); err != nil {
					t.Fatal(err)
				}
			}
			events := []map[string]any{}
			paused := map[any]bool{}
			next := func(match func(map[string]any) bool) map[string]any {
				t.Helper()
				for {
					for i, event := range events {
						if match(event) {
							events = append(events[:i], events[i+1:]...)
							return event
						}
					}
					typ, payload, err := wire.ReadFrame(client)
					if err != nil {
						t.Fatal(err)
					}
					var event map[string]any
					if err := json.Unmarshal(payload, &event); err != nil {
						t.Fatal(err)
					}
					if typ == wire.TypeJSON {
						if event["type"] == "error" || event["type"] == "exit" {
							t.Fatalf("unexpected transport event: %v", event)
						}
						continue
					}
					if !debug && event["method"] != nil && event["id"] != nil {
						var result any
						if event["method"] == "workspace/configuration" {
							result = []any{map[string]any{}}
						}
						send(map[string]any{"jsonrpc": "2.0", "id": event["id"], "result": result})
						continue
					}
					if debug && event["type"] == "event" {
						body, _ := event["body"].(map[string]any)
						if event["event"] == "stopped" {
							paused[body["threadId"]] = true
						}
						if event["event"] == "continued" {
							for thread := range paused {
								if body["allThreadsContinued"] == true || body["threadId"] == thread {
									paused[thread] = false
								}
							}
							kept := events[:0]
							for _, prior := range events {
								if prior["event"] == "stopped" {
									p, _ := prior["body"].(map[string]any)
									if !paused[p["threadId"]] {
										continue
									}
								}
								kept = append(kept, prior)
							}
							events = kept
						}
					}
					events = append(events, event)
				}
			}
			if !debug {
				send(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{
					"processId": nil, "rootUri": fileURI(work), "capabilities": map[string]any{"general": map[string]any{"positionEncodings": []string{"utf-16"}}},
				}})
				reply := next(func(m map[string]any) bool { return m["id"] == float64(1) })
				if reply["error"] != nil || reply["result"] == nil {
					t.Fatalf("initialize %v", reply)
				}
				send(map[string]any{"jsonrpc": "2.0", "method": "initialized", "params": map[string]any{}})
				send(map[string]any{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": map[string]any{"textDocument": map[string]any{
					"uri": fileURI(program), "languageId": "dart", "version": 1, "text": "void main() {\n  int value = 'wrong';\n}\n",
				}}})
				diagnostic := next(func(m map[string]any) bool {
					if m["method"] != "textDocument/publishDiagnostics" {
						return false
					}
					p, _ := m["params"].(map[string]any)
					d, _ := p["diagnostics"].([]any)
					return p["uri"] == fileURI(program) && len(d) > 0
				})
				t.Logf("real Dart diagnostics: %v", diagnostic["params"])
				send(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion", "params": map[string]any{
					"textDocument": map[string]any{"uri": fileURI(program)}, "position": map[string]any{"line": 1, "character": 2},
				}})
				reply = next(func(m map[string]any) bool { return m["id"] == float64(2) })
				if reply["error"] != nil || reply["result"] == nil {
					t.Fatalf("completion %v", reply)
				}
			} else {
				request := func(seq int, command string, args map[string]any) {
					send(map[string]any{"seq": seq, "type": "request", "command": command, "arguments": args})
				}
				response := func(seq int) map[string]any {
					reply := next(func(m map[string]any) bool { return m["type"] == "response" && m["request_seq"] == float64(seq) })
					if reply["success"] != true {
						t.Fatalf("DAP request %d: %v", seq, reply)
					}
					body, _ := reply["body"].(map[string]any)
					return body
				}
				request(1, "initialize", map[string]any{"adapterID": "dart", "clientID": "aurora", "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true, "supportsRunInTerminalRequest": false})
				response(1)
				request(2, "launch", map[string]any{"program": program, "cwd": work, "stopOnEntry": false, "console": "debugConsole"})
				next(func(m map[string]any) bool { return m["event"] == "initialized" })
				request(3, "setBreakpoints", map[string]any{"source": map[string]any{"path": program}, "breakpoints": []any{map[string]any{"line": 3}}})
				t.Logf("Dart breakpoints: %v", response(3))
				request(8, "setExceptionBreakpoints", map[string]any{"filters": []string{}})
				response(8)
				request(4, "configurationDone", map[string]any{})
				response(4)
				response(2)
				// stopOnEntry=false still emits a transient entry stop while the
				// VM starts, then resumes it automatically. Requesting its stack
				// races that resume (and can report "thread is not paused").
				// Only the configured breakpoint is the acceptance boundary.
				stopped := next(func(m map[string]any) bool {
					if m["event"] == "terminated" {
						return true
					}
					body, _ := m["body"].(map[string]any)
					return m["event"] == "stopped" && body["reason"] == "breakpoint"
				})
				if stopped["event"] == "terminated" {
					t.Fatal("target exited before the user breakpoint")
				}
				t.Logf("Dart stop reason: %v", stopped)
				thread := stopped["body"].(map[string]any)["threadId"]
				request(20, "stackTrace", map[string]any{"threadId": thread, "startFrame": 0, "levels": 20})
				frames, _ := response(20)["stackFrames"].([]any)
				if len(frames) == 0 {
					t.Fatal("no stack at the user breakpoint")
				}
				frame := frames[0].(map[string]any)
				source, _ := frame["source"].(map[string]any)
				if source["path"] != program || frame["line"] != float64(3) {
					t.Fatalf("did not stop at the configured user breakpoint: %v", frame)
				}
				request(6, "scopes", map[string]any{"frameId": frame["id"]})
				if scopes, _ := response(6)["scopes"].([]any); len(scopes) == 0 {
					t.Fatal("real Dart scopes missing")
				}
				request(7, "disconnect", map[string]any{"terminateDebuggee": true})
				response(7)
				t.Logf("real Dart stopped at %v:%v", frame["name"], frame["line"])
			}
		})
	}
}
