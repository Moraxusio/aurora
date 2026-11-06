//go:build linux

package install

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/wire"
)

// fakeSys is systemd on a directory tree. A "binary" is a text file
// "aurora3-agent VERSION [broken]"; restarting the unit runs the binary at
// BinPath, which writes its certificate and answers Hello unless broken.
type fakeSys struct {
	root      string
	active    bool
	enabled   bool
	running   string // version answering Hello; "" when not answering
	portFree  bool
	noSystemd bool
	log       []string
	failFirst string // this systemctl operation fails the first time only

	tmuxUnits   []string // running aurora3-tmux-* units
	sessions    []string
	sessionsErr error
	stopFails   map[string]bool
}

func (f *fakeSys) op(name string) error {
	f.log = append(f.log, name)
	if name == f.failFirst {
		f.failFirst = ""
		return errors.New("injected " + name)
	}
	return nil
}

func (f *fakeSys) Available() error {
	if f.noSystemd {
		return errors.New("这台机器没有以 systemd 启动，不支持安装")
	}
	return nil
}
func (f *fakeSys) IsActive(string) bool  { return f.active }
func (f *fakeSys) IsEnabled(string) bool { return f.enabled }
func (f *fakeSys) DaemonReload() error   { return f.op("daemon-reload") }
func (f *fakeSys) Enable(string) error {
	if err := f.op("enable"); err != nil {
		return err
	}
	if !exists(filepath.Join(f.root, UnitPath)) {
		return errors.New("unit file missing")
	}
	f.enabled = true
	return nil
}
func (f *fakeSys) Disable(string) error {
	if err := f.op("disable"); err != nil {
		return err
	}
	f.enabled = false
	return nil
}
func (f *fakeSys) Stop(unit string) error {
	if strings.HasPrefix(unit, "aurora3-tmux-") {
		f.log = append(f.log, "stop "+unit)
		if f.stopFails[unit] {
			return errors.New("refused to stop " + unit)
		}
		for i, u := range f.tmuxUnits {
			if u == unit {
				f.tmuxUnits = append(f.tmuxUnits[:i], f.tmuxUnits[i+1:]...)
				break
			}
		}
		f.sessions = nil
		return nil
	}
	if err := f.op("stop"); err != nil {
		return err
	}
	f.active, f.running = false, ""
	return nil
}
func (f *fakeSys) Restart(string) error {
	if err := f.op("restart"); err != nil {
		return err
	}
	f.active, f.running = false, ""
	b, err := os.ReadFile(filepath.Join(f.root, BinPath))
	if err != nil {
		return err
	}
	if !bytes.Contains(b, []byte("aurora3-agent ")) {
		return errors.New("not an agent")
	}
	c, err := entry.LoadConfig(filepath.Join(f.root, ConfigPath))
	if err != nil {
		return err // the real unit would fail the same way
	}
	if _, _, err := wire.LoadOrCreateCert(filepath.Join(f.root, c.StateDir), "agent"); err != nil {
		return err
	}
	f.active = true
	if !bytes.Contains(b, []byte("broken")) {
		f.running = strings.Fields(string(b))[1]
	}
	return nil
}
func (f *fakeSys) ResetFailed(string) {}

func (f *fakeSys) Units(string) []string { return append([]string{}, f.tmuxUnits...) }

func (f *fakeSys) TmuxSessions(string) ([]string, error) { return append([]string{}, f.sessions...), f.sessionsErr }

func (f *fakeSys) KillTmux(string) error {
	f.log = append(f.log, "kill-tmux")
	f.sessions = nil
	return nil
}

func (f *fakeSys) VerifyUnit(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	for _, l := range strings.Split(string(b), "\n") {
		if exe, ok := strings.CutPrefix(l, "ExecStart="); ok {
			fi, err := os.Stat(strings.Fields(exe)[0])
			if err != nil || fi.Mode()&0o111 == 0 {
				return fmt.Errorf("%s: Command %s is not executable", path, exe)
			}
			return nil
		}
	}
	return errors.New("no ExecStart")
}
func (f *fakeSys) BinaryVersion(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	fs := strings.Fields(string(b))
	if len(fs) < 2 || fs[0] != "aurora3-agent" {
		return "", errors.New("exec format error")
	}
	return fs[1], nil
}
func (f *fakeSys) PortFree(int) bool { return f.portFree }

func (f *fakeSys) dial(_ context.Context, addr, pin, token string) (*wire.AgentInfo, error) {
	if !f.active || f.running == "" {
		return nil, errors.New("connection refused")
	}
	c, err := entry.LoadConfig(filepath.Join(f.root, ConfigPath))
	if err != nil {
		return nil, err
	}
	want, err := readPin(filepath.Join(f.root, c.StateDir, "agent.crt"))
	if err != nil || want != pin {
		return nil, errors.New("pin mismatch")
	}
	if token != c.Token {
		return nil, errors.New("令牌错误")
	}
	if addr != "127.0.0.1:17710" {
		return nil, fmt.Errorf("unexpected addr %s", addr)
	}
	return &wire.AgentInfo{ID: "agent-1", Version: f.running, Direct: wire.DirectInfo{Port: 17710, Addrs: []string{"10.0.0.5:17710"}}}, nil
}

type rig struct {
	t    *testing.T
	root string
	sys  *fakeSys
	out  bytes.Buffer
}

// newRig is a machine with the directories every Linux server has.
func newRig(t *testing.T) *rig {
	root := t.TempDir()
	for _, d := range []string{"/usr/local/bin", "/etc/systemd/system", "/var/lib", "/run"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return &rig{t: t, root: root, sys: &fakeSys{root: root, portFree: true}}
}

// agent writes a fake agent binary of version v (optionally broken) and
// returns its path and SHA-256.
func (r *rig) agent(v string, broken bool) (string, string) {
	body := "aurora3-agent " + v
	if broken {
		body += " broken"
	}
	p := filepath.Join(r.t.TempDir(), "aurora3-agent")
	if err := os.WriteFile(p, []byte(body+"\n"), 0o755); err != nil {
		r.t.Fatal(err)
	}
	h := sha256.Sum256([]byte(body + "\n"))
	return p, hex.EncodeToString(h[:])
}

func (r *rig) env(self, version string) *Env {
	r.out.Reset()
	return &Env{Root: r.root, Sys: r.sys, Dial: r.sys.dial, Self: self, Version: version, Out: &r.out,
		Roots:          func(string) []entry.Root { return []entry.Root{{ID: "home", Path: "/root"}} },
		ConfirmTimeout: 300 * time.Millisecond, PollEvery: 10 * time.Millisecond}
}

func (r *rig) install(v string, broken bool, fault string) Result {
	self, sum := r.agent(v, broken)
	e := r.env(self, v)
	if fault != "" {
		e.fault = func(step string) error {
			if step == fault {
				return fmt.Errorf("injected at %s", step)
			}
			return nil
		}
	}
	return Run(e, Options{SHA256: sum, Name: "lab"})
}

// snapshot lists every file under root (except the lock) with its content
// hash and mode, so "unchanged" can be checked exactly.
func (r *rig) snapshot() map[string]string {
	out := map[string]string{}
	_ = filepath.WalkDir(r.root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == r.root {
			return nil
		}
		rel := strings.TrimPrefix(p, r.root)
		if rel == LockPath || rel == filepath.Dir(LockPath) {
			return nil
		}
		fi, _ := d.Info()
		v := fi.Mode().String()
		if !d.IsDir() {
			b, _ := os.ReadFile(p)
			h := sha256.Sum256(b)
			v += " " + hex.EncodeToString(h[:8])
		}
		out[rel] = v
		return nil
	})
	return out
}

func (r *rig) sysState() string {
	return fmt.Sprintf("active=%v enabled=%v running=%q", r.sys.active, r.sys.enabled, r.sys.running)
}

func same(t *testing.T, what string, a, b map[string]string) {
	t.Helper()
	var diff []string
	for k, v := range a {
		if b[k] != v {
			diff = append(diff, fmt.Sprintf("%s: %q -> %q", k, v, b[k]))
		}
	}
	for k, v := range b {
		if _, ok := a[k]; !ok {
			diff = append(diff, fmt.Sprintf("%s: added %q", k, v))
		}
	}
	sort.Strings(diff)
	if len(diff) > 0 {
		t.Fatalf("%s changed:\n  %s", what, strings.Join(diff, "\n  "))
	}
}

func (r *rig) lines() []map[string]any {
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(r.out.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			r.t.Fatalf("not JSON: %q", l)
		}
		out = append(out, m)
	}
	return out
}

func TestFreshInstall(t *testing.T) {
	r := newRig(t)
	res := r.install("3.0.1", false, "")
	if res.Result != ResultInstalled || !res.Running || res.Version != "3.0.1" || res.Previous != "" {
		t.Fatalf("result %+v", res)
	}
	if res.Direct == nil || len(res.Direct.Token) != 64 || len(res.Direct.CertSHA256) != 64 || res.Direct.Port != 17710 ||
		len(res.Direct.Addrs) != 1 || res.AgentID != "agent-1" {
		t.Fatalf("direct %+v", res.Direct)
	}
	for p, mode := range map[string]os.FileMode{BinPath: 0o755, UnitPath: 0o644, ConfigPath: 0o600, ConfigDir: 0o700 | fs.ModeDir, StateDir: 0o700 | fs.ModeDir} {
		fi, err := os.Stat(filepath.Join(r.root, p))
		if err != nil || fi.Mode() != mode {
			t.Fatalf("%s: %v %v, want %v", p, err, fi.Mode(), mode)
		}
	}
	unit, _ := os.ReadFile(filepath.Join(r.root, UnitPath))
	if string(unit) != Unit {
		t.Fatal("unit text differs")
	}
	c, err := entry.LoadConfig(filepath.Join(r.root, ConfigPath))
	if err != nil || c.Name != "lab" || c.Token != res.Direct.Token || c.Listen != ":17710" || c.StateDir != StateDir {
		t.Fatalf("config %+v %v", c, err)
	}
	if !r.sys.enabled || !r.sys.active {
		t.Fatal(r.sysState())
	}
	for _, pat := range []string{"install-*", "rollback-*"} {
		if l, _ := filepath.Glob(filepath.Join(r.root, StateDir, pat)); len(l) != 0 {
			t.Fatalf("stage or rollback dirs left: %v", l)
		}
	}
	if l := (&Env{Root: r.root}).leftovers(); len(l) != 0 {
		t.Fatalf("leftovers %v", l)
	}
	// progress: every stage starts and ends ok, then the result
	var stages []string
	for _, m := range r.lines() {
		if s, ok := m["stage"]; ok {
			stages = append(stages, fmt.Sprintf("%v:%v", s, m["status"]))
		}
	}
	want := "probe:start probe:ok prepare:start prepare:ok switch:start switch:ok confirm:start confirm:ok"
	if strings.Join(stages, " ") != want {
		t.Fatalf("stages %v", stages)
	}
	if last := r.lines()[len(r.lines())-1]; last["result"] != ResultInstalled {
		t.Fatalf("last line %v", last)
	}
	if ExitCode(res) != 0 {
		t.Fatal("exit code")
	}
}

func TestUpgradeKeepsConfigAndIdentity(t *testing.T) {
	r := newRig(t)
	first := r.install("3.0.1", false, "")
	cfgBefore, _ := os.ReadFile(filepath.Join(r.root, ConfigPath))
	res := r.install("3.0.2", false, "")
	if res.Result != ResultUpgraded || res.Previous != "3.0.1" || res.Version != "3.0.2" || r.sys.running != "3.0.2" {
		t.Fatalf("result %+v %s", res, r.sysState())
	}
	cfgAfter, _ := os.ReadFile(filepath.Join(r.root, ConfigPath))
	if !bytes.Equal(cfgBefore, cfgAfter) {
		t.Fatal("upgrade changed agent.json")
	}
	if res.Direct.Token != first.Direct.Token || res.Direct.CertSHA256 != first.Direct.CertSHA256 {
		t.Fatal("upgrade changed the token or the certificate")
	}
}

func TestSameOrOlderVersionChangesNothing(t *testing.T) {
	r := newRig(t)
	r.install("3.0.2", false, "")
	snap, st := r.snapshot(), r.sysState()
	for _, v := range []string{"3.0.2", "3.0.1"} {
		res := r.install(v, false, "")
		if res.Result != ResultUpToDate || res.Previous != "3.0.2" || res.Direct == nil || !res.Running {
			t.Fatalf("%s: %+v", v, res)
		}
		same(t, "files", snap, r.snapshot())
		if r.sysState() != st {
			t.Fatalf("system %s -> %s", st, r.sysState())
		}
	}
	if len(r.sys.log) != 3 { // daemon-reload, enable, restart of the first install
		t.Fatalf("systemctl called after the first install: %v", r.sys.log)
	}
}

func TestRefusals(t *testing.T) {
	cases := []struct {
		name  string
		setup func(r *rig)
		v     string
		sum   string // "" = correct
		want  string
	}{
		{"no systemd", func(r *rig) { r.sys.noSystemd = true }, "3.0.1", "", "systemd"},
		{"dev version", nil, "3.0.0-dev", "", "开发版本"},
		{"port taken", func(r *rig) { r.sys.portFree = false }, "3.0.1", "", "端口 17710"},
		{"wrong sha256", nil, "3.0.1", strings.Repeat("0", 64), "SHA-256"},
		{"bad sha256 flag", nil, "3.0.1", "xyz", "--sha256"},
		{"bad existing config", func(r *rig) {
			p := filepath.Join(r.root, ConfigPath)
			_ = os.MkdirAll(filepath.Dir(p), 0o700)
			_ = os.WriteFile(p, []byte("{"), 0o600)
		}, "3.0.1", "", "无法解析"},
		{"rollback left", func(r *rig) {
			_ = os.MkdirAll(filepath.Join(r.root, StateDir, "rollback-123"), 0o700)
		}, "3.0.1", "", "回滚"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t)
			if c.setup != nil {
				c.setup(r)
			}
			snap := r.snapshot()
			self, sum := r.agent(c.v, false)
			if c.sum != "" {
				sum = c.sum
			}
			res := Run(r.env(self, c.v), Options{SHA256: sum})
			if res.Result != ResultRefused || !strings.Contains(res.Message, c.want) {
				t.Fatalf("result %+v", res)
			}
			same(t, "files", snap, r.snapshot())
			if r.sys.active || r.sys.enabled || len(r.sys.log) != 0 {
				t.Fatalf("system touched: %s %v", r.sysState(), r.sys.log)
			}
			if ExitCode(res) != 1 {
				t.Fatal("exit code")
			}
		})
	}
}

func TestProbeOnlyChangesNothing(t *testing.T) {
	r := newRig(t)
	_ = os.MkdirAll(filepath.Join(r.root, "usr/local/bin"), 0o755)
	_ = os.WriteFile(filepath.Join(r.root, "usr/local/bin/aurora-agent"), []byte("v2"), 0o755) // v2 present
	snap := r.snapshot()
	self, _ := r.agent("3.0.1", false)
	res := Run(r.env(self, "3.0.1"), Options{ProbeOnly: true})
	if res.Result != ResultProbe || res.Probe == nil || !res.Probe.V2 || res.Probe.Action != "install" || !res.Probe.PortFree {
		t.Fatalf("%+v %+v", res, res.Probe)
	}
	same(t, "files", snap, r.snapshot())
}

// A failure at any step of the switch, or a new version that does not come
// up, leaves the machine exactly as before: files byte for byte and the
// service state.
func TestRollbackRestoresEverything(t *testing.T) {
	type start struct {
		name  string
		setup func(r *rig)
	}
	starts := []start{
		{"fresh machine", func(*rig) {}},
		{"running 3.0.1", func(r *rig) { r.install("3.0.1", false, "") }},
		{"installed, stopped and disabled", func(r *rig) {
			r.install("3.0.1", false, "")
			r.sys.active, r.sys.enabled, r.sys.running = false, false, ""
		}},
		{"uninstalled, config kept (D-32)", func(r *rig) {
			r.install("3.0.1", false, "")
			_ = os.Remove(filepath.Join(r.root, BinPath))
			_ = os.Remove(filepath.Join(r.root, UnitPath))
			r.sys.active, r.sys.enabled, r.sys.running = false, false, ""
		}},
	}
	type failure struct {
		name, fault string
		broken      bool
		failOp      string
		want        string
	}
	failures := []failure{
		{"before the commit (save)", "save", false, "", ResultRefused},
		{"before the commit (temps)", "temps", false, "", ResultRefused},
		{"between renames", "rename-bin", false, "", ResultRolledBack},
		{"daemon-reload fails", "", false, "daemon-reload", ResultRolledBack},
		{"restart fails", "", false, "restart", ResultRolledBack},
		{"after restart", "restart", false, "", ResultRolledBack},
		{"new version never answers", "", true, "", ResultRolledBack},
	}
	for _, s := range starts {
		for _, f := range failures {
			t.Run(s.name+"/"+f.name, func(t *testing.T) {
				r := newRig(t)
				s.setup(r)
				snap, st := r.snapshot(), r.sysState()
				// The switch's call fails; the rollback's own call succeeds.
				r.sys.failFirst = f.failOp
				res := r.install("3.0.2", f.broken, f.fault)
				if res.Result != f.want {
					t.Fatalf("result %+v", res)
				}
				same(t, "files", snap, r.snapshot())
				if r.sysState() != st {
					t.Fatalf("system %s -> %s", st, r.sysState())
				}
				if ExitCode(res) == 0 {
					t.Fatal("exit code 0 after a failure")
				}
			})
		}
	}
}

func TestRollbackFailureKeepsTheRollbackDir(t *testing.T) {
	r := newRig(t)
	r.install("3.0.1", false, "")
	self, sum := r.agent("3.0.2", true)
	e := r.env(self, "3.0.2")
	e.fault = func(step string) error {
		if step == "restore" {
			return errors.New("disk on fire")
		}
		return nil
	}
	res := Run(e, Options{SHA256: sum})
	if res.Result != ResultRollbackFailed || res.Kept == "" || !strings.Contains(res.Message, "disk on fire") {
		t.Fatalf("%+v", res)
	}
	if !isDir(filepath.Join(r.root, res.Kept)) {
		t.Fatal("rollback dir removed")
	}
	if ExitCode(res) != 3 {
		t.Fatal("exit code")
	}
	// The next run refuses until someone looks at it (D-17).
	res = r.install("3.0.2", false, "")
	if res.Result != ResultRefused || !strings.Contains(res.Message, "回滚") {
		t.Fatalf("%+v", res)
	}
}

func TestStaleStageFromADeadRunIsCleaned(t *testing.T) {
	r := newRig(t)
	stage := filepath.Join(r.root, StateDir, "install-dead")
	_ = os.MkdirAll(stage, 0o700)
	_ = os.WriteFile(filepath.Join(stage, "aurora3-agent"), []byte("x"), 0o755)
	_ = os.MkdirAll(filepath.Join(r.root, "usr/local/bin"), 0o755)
	tmp := filepath.Join(r.root, BinPath+tempSuffix+"abc")
	_ = os.WriteFile(tmp, []byte("x"), 0o755)
	res := r.install("3.0.1", false, "")
	if res.Result != ResultInstalled {
		t.Fatalf("%+v", res)
	}
	if exists(stage) || exists(tmp) {
		t.Fatal("leftovers not cleaned")
	}
}

func TestLockRefusesASecondRun(t *testing.T) {
	r := newRig(t)
	unlock, err := lock(filepath.Join(r.root, LockPath))
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	res := r.install("3.0.1", false, "")
	if res.Result != ResultRefused || !strings.Contains(res.Message, "另一个") {
		t.Fatalf("%+v", res)
	}
}

func TestDirectInfo(t *testing.T) {
	r := newRig(t)
	inst := r.install("3.0.1", false, "")
	res := DirectInfo(r.env("", "3.0.1"))
	if res.Result != ResultDirect || !res.Running || res.Direct.Token != inst.Direct.Token ||
		res.Direct.CertSHA256 != inst.Direct.CertSHA256 || res.AgentID != "agent-1" || len(res.Direct.Addrs) != 1 {
		t.Fatalf("%+v", res)
	}
	r.sys.active, r.sys.running = false, ""
	res = DirectInfo(r.env("", "3.0.1"))
	if res.Result != ResultDirect || res.Running || res.Direct.CertSHA256 != inst.Direct.CertSHA256 || res.Message == "" {
		t.Fatalf("stopped: %+v", res)
	}
}

func TestOnlyV3NamesAreWritten(t *testing.T) {
	r := newRig(t)
	r.install("3.0.1", false, "")
	r.install("3.0.2", true, "") // rolled back
	for rel := range r.snapshot() {
		ok := false
		for _, p := range []string{"/etc/aurora3", "/var/lib/aurora3", "/usr/local/bin/aurora3-agent", "/etc/systemd/system/aurora3-agent.service"} {
			if rel == p || strings.HasPrefix(rel, p+"/") {
				ok = true
			}
		}
		for _, parent := range []string{"/etc", "/etc/systemd", "/etc/systemd/system", "/var", "/var/lib", "/usr", "/usr/local", "/usr/local/bin", "/run"} {
			if rel == parent {
				ok = true
			}
		}
		if !ok {
			t.Errorf("wrote outside the v3 names: %s", rel)
		}
	}
}

func TestVerifyUnitRealFileNamesOnly(t *testing.T) {
	// Systemd.VerifyUnit treats only messages about its own file as errors.
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		t.Skip("no systemd")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "aurora3-agent")
	_ = os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755)
	u := filepath.Join(dir, UnitName)
	_ = os.WriteFile(u, []byte(strings.Replace(Unit, "ExecStart="+BinPath+" ", "ExecStart="+bin+" ", 1)), 0o644)
	if err := (Systemd{}).VerifyUnit(u); err != nil {
		t.Fatalf("good unit: %v", err)
	}
	_ = os.Chmod(bin, 0o644)
	if err := (Systemd{}).VerifyUnit(u); err == nil {
		t.Fatal("non-executable ExecStart passed")
	}
	_ = os.Chmod(bin, 0o755)
	_ = os.WriteFile(u, []byte("[Service]\nExecStart="+bin+"\nRestart=bogus\n"), 0o644)
	if err := (Systemd{}).VerifyUnit(u); err == nil {
		t.Fatal("bad Restart= value passed")
	}
}

func TestLocalAddrAndPort(t *testing.T) {
	for in, want := range map[string]string{":17710": "127.0.0.1:17710", "0.0.0.0:9": "127.0.0.1:9", "[::]:9": "[::1]:9", "127.0.0.2:5": "127.0.0.2:5", "bad": "127.0.0.1:17710"} {
		if got := localAddr(in); got != want {
			t.Errorf("%s: %s, want %s", in, got, want)
		}
	}
	if userHome("/nonexistent", "root") != "" {
		t.Fatal("userHome")
	}
}
