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

// StatfsBounded returns usable numbers for a real directory and never blocks
// past its own deadline (it returns within the 2 s bound).
func TestStatfsBoundedOnRealDirectory(t *testing.T) {
	st, ok := StatfsBounded(t.TempDir())
	if !ok || st.Bsize <= 0 {
		t.Fatalf("statfs on a real directory: ok=%v bsize=%d", ok, st.Bsize)
	}
}
