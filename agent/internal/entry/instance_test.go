package entry

import (
	"path"
	"testing"
)

func TestValidInstance(t *testing.T) {
	for _, ok := range []string{"", "a", "alice", "bob2", "a1234567890123456"[:16]} {
		if err := ValidInstance(ok); err != nil {
			t.Errorf("%q: %v", ok, err)
		}
	}
	for _, bad := range []string{"Alice", "a-b", "1a", "a_b", ".", "..", "../x", "a/b", "a b", "a.b", "\n", "abcdefghijklmnopq", "tmux", "upgrade", "agent", "default", "install"} {
		if ValidInstance(bad) == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

// No name or glob of one instance may match another's, including the default.
func TestLayoutsNeverOverlap(t *testing.T) {
	names := []string{"", "a", "ab", "alice", "alicea", "bob", "b0b", "x1", "x"}
	var ls []Layout
	for _, n := range names {
		l, err := LayoutFor(n)
		if err != nil {
			t.Fatal(n, err)
		}
		ls = append(ls, l)
	}
	for i, a := range ls {
		for j, b := range ls {
			if i == j {
				continue
			}
			for what, pair := range map[string][2]string{
				"bin": {a.Bin, b.Bin}, "unit": {a.UnitPath, b.UnitPath}, "config": {a.ConfigPath, b.ConfigPath},
				"state": {a.StateDir, b.StateDir}, "socket": {a.Socket, b.Socket},
				"tmux": {a.TmuxPrefix, b.TmuxPrefix}, "upgrade": {a.UpgradeUnit, b.UpgradeUnit},
			} {
				if pair[0] == pair[1] {
					t.Errorf("%q and %q share %s %s", a.Instance, b.Instance, what, pair[0])
				}
			}
			// A tmux unit of b must not match a's systemctl pattern (and the reverse).
			if ok, _ := path.Match(a.TmuxPattern, b.TmuxPrefix+"1700000000"); ok {
				t.Errorf("pattern %s matches %s", a.TmuxPattern, b.TmuxPrefix+"1700000000")
			}
			// Directories are not nested in each other, so a recursive delete of one is safe.
			for _, d := range [][2]string{{a.ConfigDir, b.ConfigDir}, {a.StateDir, b.StateDir}} {
				if d[0] == d[1] || len(d[1]) > len(d[0]) && d[1][:len(d[0])+1] == d[0]+"/" {
					t.Errorf("%s contains %s", d[0], d[1])
				}
			}
		}
	}
}

func TestDefaultLayoutIsTheOriginal(t *testing.T) {
	l, _ := LayoutFor("")
	if l.ConfigPath != DefaultConfigPath || l.StateDir != DefaultStateDir {
		t.Fatalf("%+v", l)
	}
}

func TestConfigValidateChecksInstance(t *testing.T) {
	c := Config{Instance: "Bad", Listen: ":17711", Token: "x"}
	if c.Validate() == nil {
		t.Fatal("bad instance accepted")
	}
}
