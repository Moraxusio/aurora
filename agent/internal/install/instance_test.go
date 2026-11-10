//go:build linux

package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"aurora3/internal/entry"
	"aurora3/internal/update"
)

// D-101: one server, several agent instances, one per client. These tests put
// the default, "alice" and "bob" on one machine (one root, one fake systemd
// each) and check that nothing one of them does changes a file of another.

// on returns a rig on the same machine whose systemd runs instance inst.
func (r *rig) on(inst string) *rig {
	return &rig{t: r.t, root: r.root, sys: &fakeSys{root: r.root, portFree: true, inst: inst}}
}

func lay(t *testing.T, inst string) entry.Layout {
	t.Helper()
	l, err := entry.LayoutFor(inst)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// owns reports whether rel is a file or directory of the instance itself.
func owns(l entry.Layout, rel string) bool {
	if rel == l.Bin || rel == l.UnitPath {
		return true
	}
	for _, d := range []string{l.ConfigDir, l.StateDir} {
		if rel == d || strings.HasPrefix(rel, d+"/") {
			return true
		}
	}
	return false
}

// others is the snapshot of everything on the machine that is not the
// instance's own, apart from the two shared parents of named instances.
func (r *rig) others(inst string) map[string]string {
	l := lay(r.t, inst)
	out := map[string]string{}
	for k, v := range r.snapshot() {
		if owns(l, k) || k == entry.InstancesConfigDir || k == entry.InstancesStateDir {
			continue
		}
		out[k] = v
	}
	return out
}

func (r *rig) config(inst string) *entry.Config {
	r.t.Helper()
	c, err := entry.LoadConfig(filepath.Join(r.root, lay(r.t, inst).ConfigPath))
	if err != nil {
		r.t.Fatal(err)
	}
	return c
}

func installed(t *testing.T, r *rig, version string) {
	t.Helper()
	if got := r.install(version, false, ""); got.Result != ResultInstalled {
		t.Fatalf("%q: %+v", r.sys.inst, got)
	}
}

func binVersion(t *testing.T, m *rig, inst string) string {
	t.Helper()
	v, err := m.sys.BinaryVersion(filepath.Join(m.root, lay(t, inst).Bin))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestInstancesInstallSideBySide(t *testing.T) {
	m := newRig(t)
	def, alice, bob := m, m.on("alice"), m.on("bob")
	installed(t, def, "3.0.1")
	installed(t, alice, "3.0.1")
	installed(t, bob, "3.0.1")

	ports := map[int]string{}
	tokens := map[string]string{}
	for _, n := range []string{"", "alice", "bob"} {
		l := lay(t, n)
		for _, p := range []string{l.Bin, l.UnitPath, l.ConfigPath} {
			if !exists(filepath.Join(m.root, p)) {
				t.Fatalf("%q: %s missing", n, p)
			}
		}
		c := m.config(n)
		if c.Instance != n || c.StateDir != l.StateDir {
			t.Fatalf("%q: config %+v", n, c)
		}
		if !exists(filepath.Join(m.root, l.StateDir, "agent.crt")) {
			t.Fatalf("%q: no identity in %s", n, l.StateDir)
		}
		port := entry.ListenPort(c.Listen)
		if other, dup := ports[port]; dup {
			t.Fatalf("port %d shared by %q and %q", port, other, n)
		}
		ports[port] = n
		if other, dup := tokens[c.Token]; dup {
			t.Fatalf("token shared by %q and %q", other, n)
		}
		tokens[c.Token] = n
		if c.AuditLog != l.StateDir+"/audit.log" {
			t.Fatalf("%q: audit log %s", n, c.AuditLog)
		}
	}
	if ports[17710] != "" {
		t.Fatalf("the default instance must keep 17710: %v", ports)
	}
	for p, n := range ports {
		if n != "" && (p < entry.FirstInstancePort || p > entry.LastInstancePort) {
			t.Fatalf("%q got port %d outside the instance range", n, p)
		}
	}

	// The unit of a named instance points only at its own files.
	u, _ := os.ReadFile(filepath.Join(m.root, lay(t, "alice").UnitPath))
	want := "ExecStart=/usr/local/bin/aurora3-agent-alice run --config /etc/aurora3.d/alice/agent.json"
	if !strings.Contains(string(u), want) {
		t.Fatalf("unit lacks %q:\n%s", want, u)
	}
	if strings.Contains(string(u), "/etc/aurora3/agent.json") || strings.Contains(string(u), "aurora3-tmux-") {
		t.Fatalf("alice's unit mentions the default instance:\n%s", u)
	}
}

func TestInstanceUpgradeLeavesTheOthersAlone(t *testing.T) {
	m := newRig(t)
	def, alice, bob := m, m.on("alice"), m.on("bob")
	installed(t, def, "3.0.1")
	installed(t, alice, "3.0.1")
	installed(t, bob, "3.0.1")
	defState, bobState := def.sysState(), bob.sysState()

	before := m.others("alice")
	if got := alice.install("3.0.2", false, ""); got.Result != ResultUpgraded {
		t.Fatal(got)
	}
	same(t, "upgrading alice changed another instance", before, m.others("alice"))
	if binVersion(t, m, "") != "3.0.1" || binVersion(t, m, "bob") != "3.0.1" {
		t.Fatal("another instance's binary moved")
	}
	if def.sysState() != defState || bob.sysState() != bobState {
		t.Fatal("another instance's service state changed")
	}
	if binVersion(t, m, "alice") != "3.0.2" {
		t.Fatal("alice is at", binVersion(t, m, "alice"))
	}
}

func TestInstanceFailedUpgradeRollsBackOnlyItself(t *testing.T) {
	m := newRig(t)
	def, alice, bob := m, m.on("alice"), m.on("bob")
	installed(t, def, "3.0.1")
	installed(t, alice, "3.0.1")
	installed(t, bob, "3.0.1")

	before := m.others("bob")
	if got := bob.install("3.0.2", true, ""); got.Result != ResultRolledBack {
		t.Fatal(got)
	}
	same(t, "bob's rollback touched another instance", before, m.others("bob"))
	if binVersion(t, m, "bob") != "3.0.1" || bob.sys.running != "3.0.1" {
		t.Fatal("bob was not restored:", binVersion(t, m, "bob"), bob.sys.running)
	}
	// The failure record is bob's: the same version still installs for alice.
	if bad, _ := update.FailureFor(filepath.Join(m.root, lay(t, "").StateDir), "3.0.2"); bad {
		t.Fatal("the default instance got bob's failure record")
	}
	if bad, _ := update.FailureFor(filepath.Join(m.root, lay(t, "bob").StateDir), "3.0.2"); !bad {
		t.Fatal("bob has no failure record")
	}
	if got := alice.install("3.0.2", false, ""); got.Result != ResultUpgraded {
		t.Fatal("alice is refused because bob failed:", got)
	}
}

func TestInstanceUninstallLeavesTheOthersAlone(t *testing.T) {
	for _, purge := range []bool{false, true} {
		m := newRig(t)
		def, alice, bob := m, m.on("alice"), m.on("bob")
		installed(t, def, "3.0.1")
		installed(t, alice, "3.0.1")
		installed(t, bob, "3.0.1")

		before := m.others("alice")
		res := Uninstall(alice.env("", "3.0.1"), UninstallOptions{Purge: purge})
		if res.Result != ResultUninstalled {
			t.Fatalf("purge=%v: %+v", purge, res)
		}
		same(t, "uninstalling alice changed another instance", before, m.others("alice"))
		l := lay(t, "alice")
		if exists(filepath.Join(m.root, l.Bin)) || exists(filepath.Join(m.root, l.UnitPath)) {
			t.Fatal("alice's binary or unit is still there")
		}
		if purge && (exists(filepath.Join(m.root, l.ConfigDir)) || exists(filepath.Join(m.root, l.StateDir))) {
			t.Fatal("purge kept alice's config or state")
		}
		if !purge && (!exists(filepath.Join(m.root, l.ConfigPath)) || !exists(filepath.Join(m.root, l.StateDir))) {
			t.Fatal("a plain uninstall must keep config and state (D-32)")
		}
	}
}

func TestPurgingTheDefaultKeepsNamedInstances(t *testing.T) {
	m := newRig(t)
	def, alice := m, m.on("alice")
	installed(t, def, "3.0.1")
	installed(t, alice, "3.0.1")
	before := m.others("")
	if res := Uninstall(def.env("", "3.0.1"), UninstallOptions{Purge: true}); res.Result != ResultUninstalled {
		t.Fatalf("%+v", res)
	}
	same(t, "purging the default removed a named instance", before, m.others(""))
	if !exists(filepath.Join(m.root, entry.InstancesConfigDir, "alice", "agent.json")) {
		t.Fatal("alice's config is gone")
	}
	if exists(filepath.Join(m.root, ConfigDir)) || exists(filepath.Join(m.root, StateDir)) {
		t.Fatal("the default was not purged")
	}
}

func TestPurgingTheLastNamedInstanceRemovesTheEmptyParents(t *testing.T) {
	m := newRig(t)
	alice := m.on("alice")
	installed(t, alice, "3.0.1")
	if res := Uninstall(alice.env("", "3.0.1"), UninstallOptions{Purge: true}); res.Result != ResultUninstalled {
		t.Fatalf("%+v", res)
	}
	for _, d := range []string{entry.InstancesConfigDir, entry.InstancesStateDir} {
		if exists(filepath.Join(m.root, d)) {
			t.Fatalf("%s is left behind", d)
		}
	}
}

// portsBusy is a fake systemd on which some ports are used by other programs.
type portsBusy struct {
	*fakeSys
	busy map[int]bool
}

func (p portsBusy) PortFree(port int) bool { return !p.busy[port] && p.fakeSys.PortFree(port) }

func TestInstancePortSkipsThePortsOfTheOthers(t *testing.T) {
	m := newRig(t)
	alice, bob, carol := m.on("alice"), m.on("bob"), m.on("carol")
	installed(t, alice, "3.0.1")
	installed(t, bob, "3.0.1")
	// Some other program holds the next free port: carol must not get it.
	taken := entry.ListenPort(m.config("bob").Listen) + 1
	e := carol.env("", "3.0.1")
	e.Sys = portsBusy{fakeSys: carol.sys, busy: map[int]bool{taken: true}}
	self, sum := carol.agent("3.0.1", false)
	e.Self = self
	if res := Run(e, Options{SHA256: sum, Name: "lab"}); res.Result != ResultInstalled {
		t.Fatalf("%+v", res)
	}
	got := entry.ListenPort(m.config("carol").Listen)
	if got == taken || got == entry.ListenPort(m.config("alice").Listen) || got == entry.ListenPort(m.config("bob").Listen) {
		t.Fatalf("carol got %d (alice %s, bob %s)", got, m.config("alice").Listen, m.config("bob").Listen)
	}
}

func TestInstanceNamesAreRefused(t *testing.T) {
	for _, bad := range []string{"Alice", "a-b", "1abc", "a_b", "../x", "x/y", "averyveryverylongname", "tmux", "upgrade", "agent", "default", "install", "a b"} {
		m := newRig(t)
		before := m.snapshot()
		self, sum := m.agent("3.0.1", false)
		e := m.env(self, "3.0.1")
		e.Instance = bad
		if res := Run(e, Options{SHA256: sum}); res.Result != ResultRefused {
			t.Fatalf("install %q: %+v", bad, res)
		}
		if res := Uninstall(e, UninstallOptions{}); res.Result == ResultUninstalled {
			t.Fatalf("uninstall %q: %+v", bad, res)
		}
		same(t, "a refused name changed the machine: "+bad, before, m.snapshot())
	}
}

func TestDefaultInstanceKeepsOriginalNames(t *testing.T) {
	l := lay(t, "")
	if l.Bin != BinPath || l.UnitPath != UnitPath || l.ConfigPath != ConfigPath || l.StateDir != StateDir ||
		l.Socket != "aurora3" || l.TmuxPrefix != "aurora3-tmux-" || l.UpgradeUnit != "aurora3-upgrade-" {
		t.Fatalf("%+v", l)
	}
}
