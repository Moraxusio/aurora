package terminal

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"aurora3/internal/winlocal"
	"aurora3/internal/wire"
)

func TestLocalTerminalNameMatchesClient(t *testing.T) {
	if !localName.MatchString(strings.Repeat("a", 64)) || localName.MatchString(strings.Repeat("a", 65)) {
		t.Fatal("local terminal names must share the 1–64 client limit")
	}
}

func TestLocalAttachDrainsExitAndSignalsSlowSubscriber(t *testing.T) {
	for _, overflow := range []bool{false, true} {
		t.Run(map[bool]string{false: "exit-tail", true: "slow-subscriber"}[overflow], func(t *testing.T) {
			session := &localSession{console: &winlocal.Console{}, listeners: map[chan []byte]struct{}{}, done: make(chan struct{})}
			env := &Env{sessions: map[string]*localSession{"fixture": session}}
			client, server := net.Pipe()
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() {
				defer server.Close()
				done <- env.attach(ctx, server, json.RawMessage(`{"name":"fixture"}`))
			}()
			t.Cleanup(func() { cancel(); client.Close(); <-done })
			client.SetDeadline(time.Now().Add(5 * time.Second))
			if _, _, err := wire.ReadFrame(client); err != nil {
				t.Fatal(err)
			}
			// A pong proves that the listener has been installed.
			if err := wire.WriteJSON(client, wire.TerminalControl{Type: "ping", Code: 1}); err != nil {
				t.Fatal(err)
			}
			if _, _, err := wire.ReadFrame(client); err != nil {
				t.Fatal(err)
			}
			session.mu.Lock()
			for ch := range session.listeners {
				if overflow {
					close(ch)
					delete(session.listeners, ch)
				} else {
					for i := 0; i < 16; i++ {
						ch <- []byte("tail\n")
					}
				}
			}
			if !overflow {
				close(session.done)
			}
			session.mu.Unlock()
			chunks := 0
			for {
				kind, data, err := wire.ReadFrame(client)
				if err != nil {
					t.Fatal(err)
				}
				if kind == wire.TypeData {
					chunks++
					continue
				}
				var event wire.TerminalControl
				if err := json.Unmarshal(data, &event); err != nil {
					t.Fatal(err)
				}
				want := "exit"
				if overflow {
					want = "detached"
				}
				if event.Type != want || (!overflow && chunks != 16) {
					t.Fatalf("event=%s chunks=%d, want %s and complete tail", event.Type, chunks, want)
				}
				break
			}
		})
	}
}
