//go:build linux

package files

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"aurora3/internal/wire"
)

type recorder struct{ events []string }

func (r *recorder) Write(event string, _ map[string]any) { r.events = append(r.events, event) }

func newEnv(t *testing.T) (*Env, string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "inside.txt"), []byte("ok\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return &Env{Roots: []Root{{ID: "home", Label: "home", Path: dir}}, UploadMaxBytes: 1 << 20, Audit: &recorder{}}, dir
}

func call(t *testing.T, e *Env, fn func(*Env, context.Context, json.RawMessage) (any, error), args map[string]any) (any, error) {
	t.Helper()
	b, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	return fn(e, context.Background(), b)
}

// TestFsErrNotEmptyIsNotExists is ported unchanged from v2 fserr_test.go.
// ENOTEMPTY is also reported as fs.ErrExist; the message must say the folder
// is not empty.
func TestFsErrNotEmptyIsNotExists(t *testing.T) {
	err := fsErr(fmt.Errorf("remove x: %w", syscall.ENOTEMPTY))
	if wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("code %v", wire.CodeOf(err))
	}
	if err.Error() != "目录不为空" {
		t.Fatalf("message %q", err.Error())
	}
	if e := fsErr(fmt.Errorf("create x: %w", fs.ErrExist)); e.Error() != "已存在同名文件或目录" {
		t.Fatalf("exists message %q", e.Error())
	}
}

// Paths that climb out of the root are refused (D-44 is about services; this
// is the files service's own boundary). Each case must fail; none may touch a
// file outside the root.
func TestTraversalOutsideRootIsRefused(t *testing.T) {
	e, dir := newEnv(t)
	outside := filepath.Join(filepath.Dir(dir), "secret-outside.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(outside) })

	for _, p := range []string{"/../secret-outside.txt", "../secret-outside.txt", "/a/../../secret-outside.txt"} {
		if _, err := call(t, e, (*Env).fsRead, map[string]any{"root": "home", "path": p}); err == nil {
			t.Fatalf("fs.read %q succeeded; it must be refused", p)
		}
		if _, err := call(t, e, (*Env).fsStat, map[string]any{"root": "home", "path": p}); err == nil {
			t.Fatalf("fs.stat %q succeeded; it must be refused", p)
		}
	}
	if _, err := call(t, e, (*Env).fsDelete, map[string]any{"root": "home", "path": "/../secret-outside.txt"}); err == nil {
		t.Fatal("fs.delete outside the root succeeded")
	}
	if b, err := os.ReadFile(outside); err != nil || string(b) != "secret" {
		t.Fatalf("file outside the root was modified: %q %v", b, err)
	}
}

// Reading and writing inside the root still work, so the refusals above are
// not just a broken service.
func TestInsideRootStillWorks(t *testing.T) {
	e, _ := newEnv(t)
	res, err := call(t, e, (*Env).fsRead, map[string]any{"root": "home", "path": "/inside.txt"})
	if err != nil {
		t.Fatalf("fs.read inside the root: %v", err)
	}
	if !strings.Contains(fmt.Sprint(res), "ok") {
		t.Fatalf("fs.read content: %v", res)
	}
	if _, err := call(t, e, (*Env).fsWrite, map[string]any{"root": "home", "path": "/new.txt", "content": "hello", "create": true}); err != nil {
		t.Fatalf("fs.write inside the root: %v", err)
	}
	if len(e.Audit.(*recorder).events) != 1 {
		t.Fatalf("audit events %v, want one fs.write", e.Audit.(*recorder).events)
	}
}

// fs.write refuses an unknown root instead of falling through to another.
func TestUnknownRootRefused(t *testing.T) {
	e, _ := newEnv(t)
	if _, err := call(t, e, (*Env).fsList, map[string]any{"root": "nope", "path": "/"}); wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("unknown root: code %v (%v)", wire.CodeOf(err), err)
	}
}
