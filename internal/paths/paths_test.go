//go:build linux

package paths

import (
	"os"
	"path/filepath"
	"testing"

	"aurora3/internal/wire"
)

// A path that climbs out of the root gets v2's forbidden code and message.
func TestDotDotGivesForbidden(t *testing.T) {
	_, err := Clean("/a/../../etc")
	err = WireError(err)
	if wire.CodeOf(err) != wire.CodeForbidden || err.Error() != "不允许访问根目录以外的路径" {
		t.Fatalf("code %v message %q", wire.CodeOf(err), err)
	}
}

// A path with a NUL or backslash is a bad request, as in v2.
func TestMalformedGivesBadRequest(t *testing.T) {
	for _, p := range []string{"/a\x00b", "/a\\b"} {
		_, err := Clean(p)
		err = WireError(err)
		if wire.CodeOf(err) != wire.CodeBadRequest || err.Error() != "路径无效" {
			t.Fatalf("%q: code %v message %q", p, wire.CodeOf(err), err)
		}
	}
}

// Resolve refuses a symlink that points outside the root.
func TestResolveRefusesSymlinkOutside(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "root")
	outside := filepath.Join(base, "outside")
	for _, d := range []string{root, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve(root, "/escape"); err != ErrOutside {
		t.Fatalf("symlink out of root: err %v, want ErrOutside", err)
	}
}

// Resolve accepts a real path inside the root.
func TestResolveInside(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	abs, err := Resolve(root, "/sub")
	if err != nil {
		t.Fatalf("inside: %v", err)
	}
	if !Within(root, abs) {
		t.Fatalf("resolved %q is not inside %q", abs, root)
	}
}

// ForeignMounts always includes the virtual filesystems when walking /.
func TestForeignMountsCoversVirtualFS(t *testing.T) {
	m := ForeignMounts("/")
	for _, p := range []string{"/proc", "/sys", "/dev", "/run"} {
		if !m[p] {
			t.Fatalf("walking / must skip %s", p)
		}
	}
}
