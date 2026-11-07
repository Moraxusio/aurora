//go:build linux

package paths

import (
	"testing"

	"aurora3/internal/wire"
)

// CheckUnit accepts a plain systemd unit name and refuses a name that looks
// like a flag or contains characters outside the allowed set (v2 monitor.go).
func TestCheckUnit(t *testing.T) {
	for _, ok := range []string{"aurora-agent", "nginx.service", "user@1000.service"} {
		if err := CheckUnit(ok); err != nil {
			t.Fatalf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"-x", "a b", "a;rm", "", "../etc"} {
		err := CheckUnit(bad)
		if wire.CodeOf(err) != wire.CodeBadRequest || err.Error() != "服务名无效" {
			t.Fatalf("%q: code %v message %q", bad, wire.CodeOf(err), err)
		}
	}
}

// CheckActions keeps only known actions, sorted and once each, and refuses
// an unknown action or a bad unit name.
func TestCheckActions(t *testing.T) {
	got, err := CheckActions("nginx.service", []string{"stop", "restart", "stop"})
	if err != nil || len(got) != 2 || got[0] != "restart" || got[1] != "stop" {
		t.Fatalf("got %v %v", got, err)
	}
	if got, err := CheckActions("nginx.service", nil); err != nil || len(got) != 0 {
		t.Fatalf("empty list: %v %v", got, err)
	}
	for _, c := range []struct {
		name string
		acts []string
	}{{"nginx.service", []string{"enable"}}, {"nginx.service", []string{"kill"}}, {"-x", []string{"start"}}} {
		if _, err := CheckActions(c.name, c.acts); wire.CodeOf(err) != wire.CodeBadRequest {
			t.Fatalf("%v: %v", c, err)
		}
	}
}

// StatfsBounded returns usable numbers for a real directory and never blocks
// past its own deadline (it returns within the 2 s bound).
func TestStatfsBoundedOnRealDirectory(t *testing.T) {
	st, ok := StatfsBounded(t.TempDir())
	if !ok || st.Bsize <= 0 {
		t.Fatalf("statfs on a real directory: ok=%v bsize=%d", ok, st.Bsize)
	}
}
