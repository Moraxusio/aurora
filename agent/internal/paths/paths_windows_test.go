package paths

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsRootBoundaries(t *testing.T) {
	for _, p := range []string{"../x", "/a/../x", "/C:/Windows", "/file:stream", "/NUL", "/trailing.", `/a\b`} {
		if _, err := Clean(p); err == nil {
			t.Fatalf("accepted %q", p)
		}
	}
	if Within(`C:\work`, `C:\work-other`) {
		t.Fatal("prefix escape")
	}
	if Within(`C:\work`, `D:\work`) {
		t.Fatal("volume escape")
	}
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "中文 空格"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := Resolve(dir, "/中文 空格"); err != nil {
		t.Fatal(err)
	}
}
