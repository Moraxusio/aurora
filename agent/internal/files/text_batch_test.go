package files

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

func TestTextCodecsRoundTripBOMAndLegacyEncodings(t *testing.T) {
	for _, name := range []string{"utf-8", "utf-8-bom", "utf-16le", "utf-16le-bom", "utf-16be", "utf-16be-bom", "gb18030", "big5", "shift-jis", "windows-1252"} {
		t.Run(name, func(t *testing.T) {
			text := []byte("hello\r\n")
			if name == "windows-1252" {
				text = []byte("café\r\n")
			} else {
				text = []byte("中文\r\n")
			}
			data, err := encodeText(text, name)
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := decodeText(data, name)
			if err != nil || !bytes.Equal(decoded, text) {
				t.Fatalf("roundtrip %s %v", decoded, err)
			}
		})
	}
	if _, err := decodeText([]byte{0xff, 0, 0x80}, "utf-8"); err == nil {
		t.Fatal("invalid bytes became editable")
	}
	if _, err := encodeText([]byte("中文"), "windows-1252"); err == nil {
		t.Fatal("unrepresentable characters were silently lost")
	}
	if _, err := decodeText([]byte{0x81}, "gb18030"); err == nil {
		t.Fatal("incomplete legacy character accepted")
	}
}

func TestTextStreamFramesLargeUTF8AndWindowsWithoutLoadingWholeFile(t *testing.T) {
	root := t.TempDir()
	text := strings.Repeat("中文 line\r\n", 200000)
	if err := os.WriteFile(filepath.Join(root, "large.txt"), []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	e := &Env{Roots: []Root{{ID: "work", Path: root}}}
	read := func(args map[string]any) (map[string]any, []byte) {
		t.Helper()
		server, client := net.Pipe()
		defer client.Close()
		client.SetDeadline(time.Now().Add(5 * time.Second))
		raw, _ := json.Marshal(args)
		done := make(chan error, 1)
		go func() { done <- e.fsText(context.Background(), server, raw); server.Close() }()
		var ack struct {
			OK   bool           `json:"ok"`
			Data map[string]any `json:"result"`
		}
		if err := wire.ReadJSON(client, &ack); err != nil || !ack.OK {
			t.Fatalf("text ack %+v %v", ack, err)
		}
		var content []byte
		for {
			typ, data, err := wire.ReadFrame(client)
			if err != nil {
				t.Fatal(err)
			}
			if typ == wire.TypeEnd {
				break
			}
			if typ != wire.TypeData || len(data) > wire.DataChunk {
				t.Fatal("invalid text frame")
			}
			content = append(content, data...)
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		return ack.Data, content
	}
	meta, data := read(map[string]any{"root": "work", "path": "/large.txt"})
	if string(data) != text {
		t.Fatal("streaming editor read changed text")
	}
	var joined []byte
	offset := float64(0)
	// Small windows deliberately cut Unicode characters and CRLF boundaries.
	for i := 0; i < 12; i++ {
		part, data := read(map[string]any{"root": "work", "path": "/large.txt", "window": true, "offset": offset, "length": 31, "if_match": meta["etag"]})
		if len(data) == 0 {
			t.Fatal("window failed to advance")
		}
		joined = append(joined, data...)
		offset = part["nextOffset"].(float64)
	}
	if !bytes.Equal(joined, []byte(text)[:int(offset)]) {
		t.Fatal("window boundaries skipped or duplicated bytes")
	}
	if err := os.Truncate(filepath.Join(root, "large.txt"), 64<<20); err != nil {
		t.Fatal(err)
	}
	large, data := read(map[string]any{"root": "work", "path": "/large.txt"})
	if large["large"] != true || len(data) != 0 {
		t.Fatal("large file was loaded into editor memory")
	}
}

func TestBatchCommitStagesOutsideLockAndChecksWholeBatch(t *testing.T) {
	for _, mode := range []string{"commit", "conflict", "cancel", "encoding-error"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			e := &Env{StateDir: t.TempDir(), Roots: []Root{{ID: "work", Path: root}}, Audit: commitAudit{}}
			for _, name := range []string{"a", "b"} {
				if err := os.WriteFile(filepath.Join(root, name), []byte("before"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			tag := func(name string) string {
				fi, err := os.Stat(filepath.Join(root, name))
				if err != nil {
					t.Fatal(err)
				}
				return etag(fi)
			}
			encoding := "utf-16le-bom"
			if mode == "encoding-error" {
				encoding = "windows-1252"
			}
			data := []byte("中文 after")
			modeBits := uint32(0o755)
			changes := []batchItem{
				{Root: "work", Path: "/a", IfMatch: tag("a"), Size: len(data), Encoding: encoding},
				{Root: "work", Path: "/b", IfMatch: tag("b"), Delete: true},
				{Root: "work", Path: "/deep/nested/new", Create: true, Size: 3, ModeBits: &modeBits},
			}
			raw, _ := json.Marshal(map[string]any{"changes": changes})
			server, client := net.Pipe()
			defer client.Close()
			client.SetDeadline(time.Now().Add(5 * time.Second))
			done := make(chan error, 1)
			go func() {
				err := e.fsCommit(context.Background(), server, raw)
				if err != nil {
					_ = wire.WriteJSON(server, wire.ErrResponse(err))
				}
				server.Close()
				done <- err
			}()
			var ack wire.Response
			if err := wire.ReadJSON(client, &ack); err != nil || !ack.OK {
				t.Fatalf("batch ack %v %v", ack, err)
			}
			// Admission does not occupy CommitMu while awaiting file bytes.
			saved := make(chan error, 1)
			go func() {
				_, err := e.fsWrite(context.Background(), json.RawMessage(`{"root":"work","path":"/other","content":"independent","create":true}`))
				saved <- err
			}()
			select {
			case err := <-saved:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("stream reception held the shared commit lock")
			}
			if mode == "conflict" {
				if err := os.WriteFile(filepath.Join(root, "b"), []byte("external"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if mode == "cancel" {
				client.Close()
			} else {
				if err := wire.WriteFrame(client, wire.TypeData, data); err != nil {
					t.Fatal(err)
				}
				if mode != "encoding-error" {
					if err := wire.WriteFrame(client, wire.TypeData, []byte("new")); err != nil {
						t.Fatal(err)
					}
					if err := wire.WriteFrame(client, wire.TypeEnd, nil); err != nil {
						t.Fatal(err)
					}
				}
				var result wire.Response
				if err := wire.ReadJSON(client, &result); err != nil {
					t.Fatal(err)
				}
				if result.OK != (mode == "commit") {
					t.Fatalf("result %v", result)
				}
			}
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("batch leaked")
			}
			a, _ := os.ReadFile(filepath.Join(root, "a"))
			b, _ := os.ReadFile(filepath.Join(root, "b"))
			if mode == "commit" {
				decoded, err := decodeText(a, encoding)
				if err != nil || !bytes.Equal(decoded, data) {
					t.Fatal("wrong encoded commit")
				}
				if _, err := os.Stat(filepath.Join(root, "b")); !os.IsNotExist(err) {
					t.Fatal("delete not committed")
				}
				if got, _ := os.ReadFile(filepath.Join(root, "deep", "nested", "new")); string(got) != "new" {
					t.Fatal("create not committed")
				}
			} else {
				if string(a) != "before" {
					t.Fatal("batch partially changed a")
				}
				want := "before"
				if mode == "conflict" {
					want = "external"
				}
				if string(b) != want {
					t.Fatal("external version lost")
				}
				if _, err := os.Stat(filepath.Join(root, "deep", "nested", "new")); !os.IsNotExist(err) {
					t.Fatal("failed batch created a file")
				}
			}
		})
	}
}
