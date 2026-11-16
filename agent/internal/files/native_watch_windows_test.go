package files

import (
	"context"
	"encoding/binary"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
	"unicode/utf16"

	"aurora3/internal/wire"
	"golang.org/x/sys/windows"
)

func TestNativeWatchOpensConfinedDirectory(t *testing.T) {
	e := &Env{Roots: []Root{{ID: "work", Path: t.TempDir()}}}
	port, err := windows.CreateIoCompletionPort(windows.InvalidHandle, 0, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(port)
	w, err := e.openNativeWatch(port, 1, winWatchItem{Root: "work", Path: "/"})
	if err != nil {
		t.Fatalf("open native watch: %v", err)
	}
	w.stop()
	var n uint32
	var id uintptr
	var overlapped *windows.Overlapped
	_ = windows.GetQueuedCompletionStatus(port, &n, &id, &overlapped, 3000)
	if id != 1 || overlapped == nil {
		t.Fatal("cancel completion missing")
	}
	w.release()
}

func TestNativeWatcherReportsWritesAndClosesPendingIO(t *testing.T) {
	root := t.TempDir()
	e := &Env{Roots: []Root{{ID: "work", Path: root}}}
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- e.fsWatch(ctx, server, nil) }()
	var ack map[string]any
	if err := wire.ReadJSON(client, &ack); err != nil || ack["ok"] != true {
		t.Fatalf("ack: %v %v", ack, err)
	}
	if err := wire.WriteJSON(client, map[string]any{"type": "set", "items": []any{
		map[string]any{"root": "work", "path": "/"},
	}}); err != nil {
		t.Fatal(err)
	}
	var first map[string]any
	if err := wire.ReadJSON(client, &first); err != nil {
		t.Fatal(err)
	}
	if first["type"] != "status" || first["native"] != float64(1) || first["fallback"] != float64(0) {
		t.Fatalf("test did not use ReadDirectoryChangesW: %v", first)
	}
	if err := wire.ReadJSON(client, &first); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "new-file.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	var event map[string]any
	if err := wire.ReadJSON(client, &event); err != nil {
		t.Fatal(err)
	}
	if event["type"] != "change" || event["root"] != "work" {
		t.Fatalf("event: %v", event)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("pending ReadDirectoryChanges IO did not cancel")
	}
}

func TestNativeNotificationDecoderRejectsTruncatedRecords(t *testing.T) {
	name := utf16.Encode([]rune("中文.txt"))
	data := make([]byte, 12+len(name)*2)
	binary.LittleEndian.PutUint32(data[8:], uint32(len(name)*2))
	for i, c := range name {
		binary.LittleEndian.PutUint16(data[12+i*2:], c)
	}
	names, ok := nativeWatchNames(data)
	if !ok || len(names) != 1 || names[0] != "中文.txt" {
		t.Fatalf("names: %v %v", names, ok)
	}
	if _, ok := nativeWatchNames(data[:len(data)-1]); ok {
		t.Fatal("accepted incomplete notification")
	}
	// Also exercise malformed offsets rather than indexing beyond the buffer.
	binary.LittleEndian.PutUint32(data, 0xfffffff0)
	if _, ok := nativeWatchNames(data); ok {
		t.Fatal("accepted malformed offset")
	}
}

func TestNativeWatchRebindsReplacedDirectoryAndReportsFallback(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "watched")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	e := &Env{Roots: []Root{{ID: "work", Path: root}}}
	server, client := net.Pipe()
	defer client.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- e.fsWatch(ctx, server, nil) }()
	client.SetDeadline(time.Now().Add(8 * time.Second))
	readUntil := func(match func(map[string]any) bool) map[string]any {
		t.Helper()
		for {
			var event map[string]any
			if err := wire.ReadJSON(client, &event); err != nil {
				t.Fatal(err)
			}
			if match(event) {
				return event
			}
		}
	}
	readUntil(func(m map[string]any) bool { return m["ok"] == true })
	if err := wire.WriteJSON(client, map[string]any{"type": "set", "items": []winWatchItem{
		{Root: "work", Path: "/watched"}, {Root: "work", Path: "/missing"},
	}}); err != nil {
		t.Fatal(err)
	}
	status := readUntil(func(m map[string]any) bool { return m["type"] == "status" })
	if status["native"] != float64(1) || status["fallback"] != float64(1) {
		t.Fatalf("status: %v", status)
	}
	readUntil(func(m map[string]any) bool { return m["type"] == "change" && m["path"] == "/watched" })
	if err := os.Rename(dir, dir+"-old"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	readUntil(func(m map[string]any) bool {
		return m["type"] == "change" && m["path"] == "/watched" && m["self"] == true && m["native"] == true
	})
	if err := os.WriteFile(filepath.Join(dir, "replacement.txt"), []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	readUntil(func(m map[string]any) bool {
		for _, name := range anyNames(m["names"]) {
			if name == "replacement.txt" {
				return true
			}
		}
		return false
	})
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("watch cleanup hung")
	}
}

func anyNames(value any) []string {
	var out []string
	values, _ := value.([]any)
	for _, name := range values {
		if text, ok := name.(string); ok {
			out = append(out, text)
		}
	}
	return out
}

func TestNativeWatchRefusesOutOfRootDirectory(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Skip(err)
	}
	e := &Env{Roots: []Root{{ID: "work", Path: root}}}
	port, err := windows.CreateIoCompletionPort(windows.InvalidHandle, 0, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(port)
	if w, err := e.openNativeWatch(port, 1, winWatchItem{Root: "work", Path: "/escape"}); err == nil {
		w.stop()
		var n uint32
		var key uintptr
		var ov *windows.Overlapped
		_ = windows.GetQueuedCompletionStatus(port, &n, &key, &ov, windows.INFINITE)
		w.release()
		t.Fatal("escaped root")
	}
}
