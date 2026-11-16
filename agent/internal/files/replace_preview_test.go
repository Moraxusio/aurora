package files

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

func TestReplacementSharesSearchSemanticsAndPreservesSeparators(t *testing.T) {
	cases := []struct {
		text, query, replacement, want string
		regex, word, matchCase         bool
		count                          int
	}{
		{"Cat cat scatter\r\ncat\r\n", "cat", "$1", "$1 $1 scatter\r\n$1\r\n", false, true, false, 3},
		{"中文42\r\n中文7\n", `(?P<name>中文)(\d+)`, `${name}:$2:$$`, "中文:42:$\r\n中文:7:$\n", true, false, true, 2},
		{"first\r\nsecond\r\n", `^(\w+)$`, "[$1]", "[first]\r\n[second]\r\n", true, false, true, 2},
		{"Cat cat", "cat", "", "Cat ", false, false, true, 1},
	}
	for _, c := range cases {
		re, err := buildMatcher(c.query, c.regex, c.matchCase, c.word)
		if err != nil {
			t.Fatal(err)
		}
		parts, err := replacementParts(c.replacement, re, c.regex)
		if err != nil {
			t.Fatal(err)
		}
		out, count, err := replaceTextPreview(context.Background(), []byte(c.text), re, parts)
		if err != nil || string(out) != c.want || count != c.count {
			t.Fatalf("%q: got %q/%d, want %q/%d: %v", c.query, out, count, c.want, c.count, err)
		}
		if len(matchLines([]byte(c.text), re, 100)) == 0 {
			t.Fatal("replacement disagrees with search")
		}
	}
}

func TestReplacementBudgetsCancellationAndLinearRegex(t *testing.T) {
	re, _ := buildMatcher("(a)", true, true, false)
	if _, err := replacementParts("$2", re, true); err == nil {
		t.Fatal("unknown group accepted")
	}
	parts, _ := replacementParts(strings.Repeat("$1", 1000), re, true)
	if _, _, err := replaceTextPreview(context.Background(), []byte(strings.Repeat("a", 5000)), re, parts); err == nil {
		t.Fatal("unbounded output expansion")
	}
	parts, _ = replacementParts("x", re, true)
	if _, _, err := replaceTextPreview(context.Background(), []byte(strings.Repeat("a", maxReplacements+1)), re, parts); err == nil {
		t.Fatal("unbounded match count")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := replaceTextPreview(ctx, []byte("a"), re, parts); err != context.Canceled {
		t.Fatal(err)
	}
	// A backtracking engine can stall on this input. Go's RE2 stays bounded.
	re, _ = buildMatcher("(a+)+$", true, true, false)
	text := []byte(strings.Repeat("a", 1<<20) + "!")
	if _, count, err := replaceTextPreview(context.Background(), text, re, parts); err != nil || count != 0 {
		t.Fatal(count, err)
	}
}

func TestReplacementStreamsUnsavedSnapshotAndResetsReleaseBudget(t *testing.T) {
	env := &Env{}
	for _, cancel := range []bool{false, true} {
		server, client := net.Pipe()
		client.SetDeadline(time.Now().Add(3 * time.Second))
		text := []byte("未保存 cat\r\n")
		raw, _ := json.Marshal(map[string]any{"query": "cat", "replacement": "dog", "size": len(text)})
		done := make(chan error, 1)
		go func() {
			err := env.fsReplacePreview(context.Background(), server, raw)
			if err != nil {
				_ = wire.WriteJSON(server, wire.ErrResponse(err))
			}
			server.Close()
			done <- err
		}()
		var ack wire.Response
		if err := wire.ReadJSON(client, &ack); err != nil || !ack.OK {
			t.Fatal(ack, err)
		}
		if cancel {
			client.Close()
		} else {
			if err := wire.WriteFrame(client, wire.TypeData, text[:2]); err != nil {
				t.Fatal(err)
			}
			if err := wire.WriteFrame(client, wire.TypeData, text[2:]); err != nil {
				t.Fatal(err)
			}
			if err := wire.WriteFrame(client, wire.TypeEnd, nil); err != nil {
				t.Fatal(err)
			}
			if err := wire.ReadJSON(client, &ack); err != nil || !ack.OK {
				t.Fatal(ack, err)
			}
			typ, data, err := wire.ReadFrame(client)
			if err != nil || typ != wire.TypeData || string(data) != "未保存 dog\r\n" {
				t.Fatal(typ, string(data), err)
			}
			if typ, _, err := wire.ReadFrame(client); err != nil || typ != wire.TypeEnd {
				t.Fatal(typ, err)
			}
			client.Close()
		}
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Fatal("preview stream leaked")
		}
		env.textMu.Lock()
		running := env.textRunning
		env.textMu.Unlock()
		if running != 0 {
			t.Fatal("preview leaked text budget")
		}
	}
}
