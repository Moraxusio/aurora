//go:build linux

package files

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"aurora3/internal/wire"
)

func twoRoots(t *testing.T) (*Env, string, string) {
	t.Helper()
	a, b := t.TempDir(), t.TempDir()
	return &Env{Roots: []Root{{ID: "home", Label: "home", Path: a}, {ID: "data", Label: "data", Path: b}}, UploadMaxBytes: 1 << 20, Audit: &recorder{}}, a, b
}

func write(t *testing.T, p, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// A folder is copied whole, inside one root and across roots, keeping file
// contents, permission bits and modification times; the source is untouched.
func TestCopyFolderSameAndAcrossRoots(t *testing.T) {
	e, home, data := twoRoots(t)
	write(t, filepath.Join(home, "src/a.txt"), "alpha", 0o640)
	write(t, filepath.Join(home, "src/sub/b.sh"), "#!/bin/sh\n", 0o755)
	if err := os.Symlink("a.txt", filepath.Join(home, "src/link")); err != nil {
		t.Fatal(err)
	}
	old := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(filepath.Join(home, "src/a.txt"), old, old); err != nil {
		t.Fatal(err)
	}

	if _, err := call(t, e, (*Env).fsCopy, map[string]any{"root": "home", "path": "/src", "to": "/dup"}); err != nil {
		t.Fatalf("same-root copy: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(home, "dup/a.txt")); string(b) != "alpha" {
		t.Fatalf("content %q", b)
	}
	fi, err := os.Stat(filepath.Join(home, "dup/a.txt"))
	if err != nil || fi.Mode().Perm() != 0o640 || !fi.ModTime().Equal(old) {
		t.Fatalf("mode/mtime not kept: %v %v", fi, err)
	}
	if fi, _ := os.Stat(filepath.Join(home, "dup/sub/b.sh")); fi == nil || fi.Mode().Perm() != 0o755 {
		t.Fatalf("exec bit lost: %v", fi)
	}
	if tgt, err := os.Readlink(filepath.Join(home, "dup/link")); err != nil || tgt != "a.txt" {
		t.Fatalf("symlink must be copied as a link: %q %v", tgt, err)
	}

	if _, err := call(t, e, (*Env).fsCopy, map[string]any{"root": "home", "path": "/src", "to_root": "data", "to": "/far"}); err != nil {
		t.Fatalf("cross-root copy: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(data, "far/sub/b.sh")); string(b) != "#!/bin/sh\n" {
		t.Fatalf("cross-root content %q", b)
	}
	if _, err := os.Stat(filepath.Join(home, "src/a.txt")); err != nil {
		t.Fatalf("source must stay: %v", err)
	}
}

func TestCopyRefusals(t *testing.T) {
	e, home, data := twoRoots(t)
	write(t, filepath.Join(home, "d/f.txt"), "x", 0o644)
	write(t, filepath.Join(home, "taken.txt"), "old", 0o644)
	write(t, filepath.Join(home, "f.txt"), "new", 0o644)

	cases := []struct {
		name string
		args map[string]any
		code string
	}{
		{"into itself", map[string]any{"root": "home", "path": "/d", "to": "/d/inner"}, wire.CodeBadRequest},
		{"onto itself", map[string]any{"root": "home", "path": "/d", "to": "/d"}, wire.CodeBadRequest},
		{"name taken", map[string]any{"root": "home", "path": "/f.txt", "to": "/taken.txt"}, wire.CodeConflict},
		{"missing target folder", map[string]any{"root": "home", "path": "/f.txt", "to": "/nope/f.txt"}, wire.CodeNotFound},
		{"missing source", map[string]any{"root": "home", "path": "/ghost", "to": "/g2"}, wire.CodeNotFound},
		{"root itself", map[string]any{"root": "home", "path": "/", "to_root": "data", "to": "/all"}, wire.CodeBadRequest},
		{"unknown target root", map[string]any{"root": "home", "path": "/f.txt", "to_root": "nope", "to": "/f.txt"}, wire.CodeNotFound},
		{"escape", map[string]any{"root": "home", "path": "/f.txt", "to_root": "data", "to": "/../escape"}, wire.CodeForbidden},
	}
	for _, c := range cases {
		if _, err := call(t, e, (*Env).fsCopy, c.args); wire.CodeOf(err) != c.code {
			t.Errorf("%s: code %v (%v), want %v", c.name, wire.CodeOf(err), err, c.code)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(home, "taken.txt")); string(b) != "old" {
		t.Fatalf("a refused copy overwrote the target: %q", b)
	}
	if _, err := os.Stat(filepath.Join(data, "escape")); err == nil {
		t.Fatal("copy escaped the root")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(data), "escape")); err == nil {
		t.Fatal("copy escaped the root")
	}
}

// A read-only folder can be copied, and the copy ends with the same bits.
func TestCopyReadOnlyFolder(t *testing.T) {
	e, home, _ := twoRoots(t)
	write(t, filepath.Join(home, "ro/f.txt"), "x", 0o444)
	if err := os.Chmod(filepath.Join(home, "ro"), 0o555); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(filepath.Join(home, "ro"), 0o755)
	defer os.Chmod(filepath.Join(home, "ro2"), 0o755)
	if _, err := call(t, e, (*Env).fsCopy, map[string]any{"root": "home", "path": "/ro", "to": "/ro2"}); err != nil {
		t.Fatalf("read-only copy: %v", err)
	}
	if fi, _ := os.Stat(filepath.Join(home, "ro2")); fi == nil || fi.Mode().Perm() != 0o555 {
		t.Fatalf("folder bits: %v", fi)
	}
	if fi, _ := os.Stat(filepath.Join(home, "ro2/f.txt")); fi == nil || fi.Mode().Perm() != 0o444 {
		t.Fatalf("file bits: %v", fi)
	}
}

// fs.du totals a folder, gives per-child totals, counts a hard link once and
// refuses a file.
func TestDuTotalsChildrenAndHardLinks(t *testing.T) {
	e, home, _ := twoRoots(t)
	write(t, filepath.Join(home, "p/one.bin"), string(make([]byte, 1000)), 0o644)
	write(t, filepath.Join(home, "p/sub/two.bin"), string(make([]byte, 500)), 0o644)
	write(t, filepath.Join(home, "p/sub/deeper/three.bin"), string(make([]byte, 250)), 0o644)
	if err := os.Link(filepath.Join(home, "p/one.bin"), filepath.Join(home, "p/hard.bin")); err != nil {
		t.Fatal(err)
	}
	res, err := call(t, e, (*Env).fsDu, map[string]any{"root": "home", "path": "/p", "children": true})
	if err != nil {
		t.Fatal(err)
	}
	r := res.(*duResult)
	if r.Bytes != 1750 || r.Files != 3 || r.Dirs != 2 || r.Partial {
		t.Fatalf("totals: %+v", r)
	}
	if c := r.Children["sub"]; c == nil || c.Bytes != 750 || c.Files != 2 || !c.Done {
		t.Fatalf("child sub: %+v", r.Children["sub"])
	}
	// the two names are one file: the first in walk order carries the bytes, the other is not counted again
	if c := r.Children["hard.bin"]; c == nil || c.Bytes != 1000 {
		t.Fatalf("child file: %+v", r.Children["hard.bin"])
	}
	if c := r.Children["one.bin"]; c != nil {
		t.Fatalf("hard link counted twice: %+v", c)
	}
	if r.Disk < r.Bytes {
		t.Fatalf("disk usage %d below apparent size %d", r.Disk, r.Bytes)
	}
	if _, err := call(t, e, (*Env).fsDu, map[string]any{"root": "home", "path": "/p/one.bin"}); wire.CodeOf(err) != wire.CodeBadRequest {
		t.Fatalf("a file must be refused: %v", err)
	}
	if _, err := call(t, e, (*Env).fsDu, map[string]any{"root": "home", "path": "/missing"}); wire.CodeOf(err) != wire.CodeNotFound {
		t.Fatalf("missing folder: %v", err)
	}
}
