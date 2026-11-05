package update

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalPathsAndResult(t *testing.T) {
	p := Paths{DataDir: t.TempDir()}
	if filepath.Base(p.StartedMarker("2.0.0+1")) != "started-2.0.0_1" {
		t.Fatal("sanitize")
	}
	if filepath.Dir(p.DownloadDir("../x")) != filepath.Join(p.DataDir, "updates") {
		t.Fatal("unsafe path")
	}
	r := LastResult{Version: "2", From: "1", OK: true, Time: 4}
	if e := WriteLastResult(p, r); e != nil {
		t.Fatal(e)
	}
	got, ok, e := ReadLastResult(p)
	if e != nil || !ok || got != r {
		t.Fatalf("%#v %v %v", got, ok, e)
	}
	p2 := Paths{DataDir: filepath.Join(t.TempDir(), "none")}
	_, ok, e = ReadLastResult(p2)
	if e != nil || ok {
		t.Fatal("missing")
	}
	_ = os.ErrNotExist
}
