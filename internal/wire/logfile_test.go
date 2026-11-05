package wire

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotatingFileStaysBounded(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.log")
	r := &RotatingFile{Path: p, Max: 1000, Mode: 0o600}
	line := strings.Repeat("x", 99) + "\n"
	for i := 0; i < 100; i++ {
		if _, err := r.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	r.Close()
	a, _ := os.Stat(p)
	b, _ := os.Stat(p + ".1")
	if a == nil || b == nil || a.Size() > 1000 || b.Size() > 1000 {
		t.Fatalf("sizes %v %v", a, b)
	}
}
