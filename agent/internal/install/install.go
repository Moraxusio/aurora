//go:build linux

// Package install puts aurora3-agent on a Linux server in four stages
// (docs/DESIGN.md 5.1; D-12, D-15 to D-17): probe, prepare, switch, confirm.
// Either the new version runs and answers on its direct port, or the machine
// is back where it was before the run. Only v3 names are written (D-71); v2's
// files are looked at, never changed (D-75).
//
// The client uploads the agent over SSH and runs `aurora3-agent install` as
// root. Progress and the result are JSON lines on stdout. All four stages run
// in this one process, so a dropped SSH connection cannot leave the machine
// between two stages: SIGHUP and SIGPIPE are ignored by the command, and
// writes to a closed stdout are dropped.
package install

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/update"
	"aurora3/internal/wire"
)

// Absolute paths on the server (D-71). Env.Root prefixes them in tests.
const (
	BinPath    = "/usr/local/bin/aurora3-agent"
	UnitName   = "aurora3-agent.service"
	UnitPath   = "/etc/systemd/system/" + UnitName
	ConfigPath = entry.DefaultConfigPath
	ConfigDir  = "/etc/aurora3"
	StateDir   = entry.DefaultStateDir
	LockPath   = "/run/aurora3-install.lock"
)

// v2's files, only checked for presence (D-75).
var v2Paths = []string{"/usr/local/bin/aurora-agent", "/etc/systemd/system/aurora-agent.service"}

// Unit is v2's unit with v3's names.
const Unit = `[Unit]
Description=Aurora 3 agent (terminals, files, monitoring)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/aurora3-agent run --config /etc/aurora3/agent.json
Restart=always
RestartSec=2
# Only the agent gets SIGTERM on stop or restart; tmux servers run in their
# own aurora3-tmux-* units and are never part of this group (D-35).
KillMode=mixed
TimeoutStopSec=15
LimitNOFILE=65536
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
`

// Results.
const (
	ResultProbe          = "probe"           // --probe: nothing was changed
	ResultInstalled      = "installed"       // first install
	ResultUpgraded       = "upgraded"        // a newer version replaced the old one
	ResultUpToDate       = "up_to_date"      // the installed version is not older (D-12): nothing was changed
	ResultDirect         = "direct"          // direct-info
	ResultRefused        = "refused"         // nothing was changed
	ResultRolledBack     = "rolled_back"     // the switch failed; the machine is as it was
	ResultRollbackFailed = "rollback_failed" // the rollback did not finish; see Kept (D-17)
)

// Result is the last line the command prints.
type Result struct {
	Result   string           `json:"result"`
	Message  string           `json:"message,omitempty"`
	Version  string           `json:"version,omitempty"`  // the version now installed
	Previous string           `json:"previous,omitempty"` // the version before this run
	AgentID  string           `json:"agent_id,omitempty"`
	Running  bool             `json:"running,omitempty"`
	Direct   *wire.DirectInfo `json:"direct,omitempty"` // includes the token (D-4)
	Probe    *Probe           `json:"probe,omitempty"`
	Kept     string           `json:"kept,omitempty"` // rollback directory left for inspection
}

// ExitCode of the command for a result.
func ExitCode(r Result) int {
	switch r.Result {
	case ResultProbe, ResultInstalled, ResultUpgraded, ResultUpToDate, ResultDirect:
		return 0
	case ResultRolledBack:
		return 2
	case ResultRollbackFailed:
		return 3
	}
	return 1
}

// Progress is printed as each stage starts and ends.
type Progress struct {
	Stage   string `json:"stage"`  // probe | prepare | switch | confirm | rollback
	Status  string `json:"status"` // start | ok | fail
	Message string `json:"message,omitempty"`
}

// Probe is what the first stage found. It changes nothing.
type Probe struct {
	Arch      string   `json:"arch"`
	OS        string   `json:"os"`
	Bundled   string   `json:"bundled"`             // this binary's version
	Installed string   `json:"installed,omitempty"` // "unknown" when the installed binary does not run
	Active    bool     `json:"active"`
	Config    bool     `json:"config"` // agent.json exists (a default uninstall keeps it, D-32)
	Port      int      `json:"port"`
	PortFree  bool     `json:"port_free"`
	V2        bool     `json:"v2"`                 // v2 is on this machine (left alone)
	Action    string   `json:"action"`             // install | upgrade | none
	Problem   string   `json:"problem,omitempty"`  // why an install would be refused
	Leftover  []string `json:"leftover,omitempty"` // left by an earlier run
}

// System is what the installer needs from systemd and the OS.
type System interface {
	Available() error // systemd is init, and systemctl, systemd-run, systemd-analyze exist
	IsActive(unit string) bool
	IsEnabled(unit string) bool
	DaemonReload() error
	Enable(unit string) error
	Disable(unit string) error
	Restart(unit string) error
	Stop(unit string) error
	// ResetFailed clears a unit's failed state and start counter, so a start
	// right after a crash loop is not refused by StartLimitBurst. Best effort.
	ResetFailed(unit string)
	VerifyUnit(path string) error
	BinaryVersion(path string) (string, error)
	PortFree(port int) bool
}

// Dialer opens a pinned TLS connection, sends Hello and returns the agent's
// description from HelloReply.
type Dialer func(ctx context.Context, addr, pin, token string) (*wire.AgentInfo, error)

// Env is the machine the installer works on.
type Env struct {
	Root           string // "/" on a server; a temporary directory in tests
	Sys            System
	Dial           Dialer
	Self           string // the running executable (what gets installed)
	Version        string // its version
	Roots          func(user string) []entry.Root
	Out            io.Writer
	ConfirmTimeout time.Duration
	PollEvery      time.Duration

	fault func(step string) error // tests: fail at a named step
}

// Options of one run.
type Options struct {
	SHA256    string // expected SHA-256 of Self, from the signed manifest (D-3)
	Name      string // server name, new installs only
	User      string // whose home is the first root, new installs only
	ProbeOnly bool
}

func (e *Env) p(abs string) string { return filepath.Join(e.Root, abs) }

// rel turns a path under Root back into the server's absolute path.
func (e *Env) rel(p string) string {
	root := filepath.Clean(e.Root)
	if root == "/" || root == "." {
		return p
	}
	return "/" + strings.TrimPrefix(strings.TrimPrefix(p, root), "/")
}

func (e *Env) emit(v any) {
	if e.Out == nil {
		return
	}
	b, _ := json.Marshal(v)
	_, _ = e.Out.Write(append(b, '\n')) // stdout may be gone with the SSH session
}

func (e *Env) step(stage, status, msg string) {
	e.emit(Progress{Stage: stage, Status: status, Message: msg})
}

func (e *Env) failAt(step string) error {
	if e.fault == nil {
		return nil
	}
	return e.fault(step)
}

// Emit prints a result line (for refusals before an Env exists).
func Emit(w io.Writer, r Result) {
	b, _ := json.Marshal(r)
	_, _ = w.Write(append(b, '\n'))
}

// Run installs or upgrades, printing progress and the result.
func Run(e *Env, o Options) Result {
	r := e.run(o)
	e.emit(r)
	return r
}

func (e *Env) run(o Options) Result {
	if e.ConfirmTimeout <= 0 {
		e.ConfirmTimeout = 30 * time.Second
	}
	if e.PollEvery <= 0 {
		e.PollEvery = 250 * time.Millisecond
	}
	// A probe changes nothing and may run without root, so it takes no lock.
	if !o.ProbeOnly {
		unlock, err := lock(e.p(LockPath))
		if err != nil {
			return Result{Result: ResultRefused, Message: err.Error()}
		}
		defer unlock()
	}

	e.step("probe", "start", "")
	pr := e.probe()
	if pr.Problem != "" {
		e.step("probe", "fail", pr.Problem)
	} else {
		e.step("probe", "ok", "")
	}
	if o.ProbeOnly {
		return Result{Result: ResultProbe, Message: pr.Problem, Previous: pr.Installed, Probe: pr}
	}
	if pr.Problem != "" {
		return Result{Result: ResultRefused, Message: pr.Problem, Previous: pr.Installed, Probe: pr}
	}
	if pr.Action == "none" {
		r := e.direct()
		r.Previous, r.Probe = pr.Installed, pr
		if r.Result == ResultRefused { // the binary is there but agent.json is not
			return r
		}
		msg := fmt.Sprintf("已安装 %s，不低于本次的 %s，未做改动", pr.Installed, e.Version)
		if r.Message != "" {
			msg += "；" + r.Message
		}
		r.Result, r.Message = ResultUpToDate, msg
		return r
	}
	if !isHex64(o.SHA256) {
		return Result{Result: ResultRefused, Message: "缺少或无效的 --sha256", Probe: pr}
	}

	e.step("prepare", "start", "")
	s, err := e.prepare(o, pr)
	if err != nil {
		e.step("prepare", "fail", err.Error())
		return Result{Result: ResultRefused, Message: "准备阶段失败，未做改动：" + err.Error(), Previous: pr.Installed, Probe: pr}
	}
	e.step("prepare", "ok", "")

	e.step("switch", "start", "")
	sw, err := e.switchOver(s, pr)
	if err != nil {
		e.step("switch", "fail", err.Error())
		if !sw.committed {
			e.dropStage(s)
			return Result{Result: ResultRefused, Message: "切换前失败，未做改动：" + err.Error(), Previous: pr.Installed, Probe: pr}
		}
		return e.rollback(s, sw, "切换失败："+err.Error())
	}
	e.step("switch", "ok", "")

	e.step("confirm", "start", "")
	info, pin, err := e.confirm(s.conf, e.Version)
	if err != nil {
		e.step("confirm", "fail", err.Error())
		return e.rollback(s, sw, "新版本没有正常运行："+err.Error())
	}
	e.step("confirm", "ok", "")

	_ = os.RemoveAll(sw.dir)
	_ = os.RemoveAll(s.dir)
	d := info.Direct
	d.CertSHA256, d.Token = pin, s.conf.Token
	res := ResultInstalled
	if pr.Installed != "" {
		res = ResultUpgraded
	}
	return Result{Result: res, Version: e.Version, Previous: pr.Installed, AgentID: info.ID, Running: true, Direct: &d}
}

// probe looks and changes nothing.
func (e *Env) probe() *Probe {
	pr := &Probe{Arch: runtime.GOARCH, OS: osName(e.p("/etc/os-release")), Bundled: e.Version, Port: portOf(entry.DefaultListen)}
	for _, v := range v2Paths {
		if exists(e.p(v)) {
			pr.V2 = true
		}
	}
	pr.Leftover = e.leftovers()
	if err := e.Sys.Available(); err != nil {
		pr.Problem = err.Error()
		return pr
	}
	if _, _, err := update.ParseVersionStrict(e.Version); err != nil {
		pr.Problem = fmt.Sprintf("这个 aurora3-agent 是开发版本（%s），不能安装", e.Version)
		return pr
	}
	if exists(e.p(BinPath)) {
		pr.Installed = "unknown"
		if v, err := e.Sys.BinaryVersion(e.p(BinPath)); err == nil && v != "" {
			pr.Installed = v
		}
	}
	pr.Active = e.Sys.IsActive(UnitName)
	if exists(e.p(ConfigPath)) {
		pr.Config = true
		c, err := entry.LoadConfig(e.p(ConfigPath))
		if err != nil {
			pr.Problem = fmt.Sprintf("现有配置 %s 无法解析：%v", ConfigPath, err)
			return pr
		}
		pr.Port = portOf(c.Listen)
	}
	for _, l := range pr.Leftover {
		if strings.HasPrefix(filepath.Base(l), "rollback-") {
			pr.Problem = fmt.Sprintf("上次安装的回滚没有完成，回滚目录 %s 还在，需要先处理", l)
			return pr
		}
	}
	pr.Action = "install"
	if pr.Installed != "" {
		pr.Action = "upgrade"
		if c, err := update.CompareVersionStrict(pr.Installed, e.Version); err == nil && c >= 0 {
			pr.Action = "none"
		}
	}
	pr.PortFree = true
	if pr.Action != "none" && !pr.Active {
		pr.PortFree = e.Sys.PortFree(pr.Port)
		if !pr.PortFree {
			pr.Problem = fmt.Sprintf("端口 %d 已被其它程序占用", pr.Port)
		}
	}
	return pr
}

// leftovers lists what an earlier run that died left behind: stage and
// rollback directories, and temporary files next to the targets. Only v3
// names match.
func (e *Env) leftovers() []string {
	var out []string
	for _, pat := range []string{
		filepath.Join(StateDir, "install-*"),
		filepath.Join(StateDir, "rollback-*"),
		tempGlob(BinPath),
		tempGlob(UnitPath),
		tempGlob(ConfigPath),
	} {
		m, _ := filepath.Glob(e.p(pat))
		for _, f := range m {
			out = append(out, e.rel(f))
		}
	}
	return out
}

// staged is the result of the prepare stage.
type staged struct {
	dir          string // StateDir/install-*
	bin          string // the copied binary
	cfg          string // new config to install; "" keeps the existing one
	conf         *entry.Config
	stateExisted bool
}

// prepare writes only into StateDir/install-* and checks what it wrote.
func (e *Env) prepare(o Options, pr *Probe) (*staged, error) {
	// Our lock is held, so stage directories and temporary files that exist
	// belong to runs that died before switching. Rollback directories never
	// get here (probe refuses).
	for _, l := range pr.Leftover {
		if !strings.HasPrefix(filepath.Base(l), "rollback-") {
			_ = os.RemoveAll(e.p(l))
		}
	}
	s := &staged{stateExisted: isDir(e.p(StateDir))}
	if err := os.MkdirAll(e.p(StateDir), 0o700); err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp(e.p(StateDir), "install-")
	if err != nil {
		e.dropStage(s)
		return nil, err
	}
	s.dir = dir
	ok := false
	defer func() {
		if !ok {
			e.dropStage(s)
		}
	}()

	s.bin = filepath.Join(dir, "aurora3-agent")
	sum, err := copyFile(e.Self, s.bin, 0o755)
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(sum, o.SHA256) {
		return nil, fmt.Errorf("上传的程序 SHA-256 为 %s，与签名清单的 %s 不符", sum, strings.ToLower(o.SHA256))
	}
	if v, err := e.Sys.BinaryVersion(s.bin); err != nil {
		return nil, fmt.Errorf("新程序无法在这台机器上运行：%w", err)
	} else if v != e.Version {
		return nil, fmt.Errorf("新程序报告版本 %q，应为 %q", v, e.Version)
	}

	if pr.Config {
		c, err := entry.LoadConfig(e.p(ConfigPath))
		if err != nil {
			return nil, fmt.Errorf("现有配置无法解析：%w", err)
		}
		s.conf = c
	} else {
		user := o.User
		if user == "" {
			user = "root"
		}
		c := &entry.Config{Name: o.Name, Listen: entry.DefaultListen, Token: wire.NewToken(), StateDir: StateDir,
			Roots: e.Roots(user), AuditLog: StateDir + "/audit.log"}
		if err := c.Validate(); err != nil {
			return nil, err
		}
		s.cfg = filepath.Join(dir, "agent.json")
		if err := c.Save(s.cfg); err != nil {
			return nil, err
		}
		back, err := entry.LoadConfig(s.cfg)
		if err != nil {
			return nil, fmt.Errorf("新配置无法解析：%w", err)
		}
		s.conf = back
	}

	// The unit is checked as written, except that ExecStart points at the
	// staged copy, which must exist and be executable for the check to pass.
	vu := filepath.Join(dir, UnitName)
	text := strings.Replace(Unit, "ExecStart="+BinPath+" ", "ExecStart="+s.bin+" ", 1)
	if err := os.WriteFile(vu, []byte(text), 0o644); err != nil {
		return nil, err
	}
	if err := e.Sys.VerifyUnit(vu); err != nil {
		return nil, fmt.Errorf("systemd 单元检查未通过：%w", err)
	}
	if err := e.failAt("prepare"); err != nil {
		return nil, err
	}
	ok = true
	return s, nil
}

func (e *Env) dropStage(s *staged) {
	if s.dir != "" {
		_ = os.RemoveAll(s.dir)
	}
	if !s.stateExisted {
		_ = os.Remove(e.p(StateDir)) // only if nothing else is in it
	}
}

// before is the state the switch replaced, kept in the rollback directory.
type before struct {
	Bin       bool   `json:"bin"`
	Unit      bool   `json:"unit"`
	Config    bool   `json:"config"`
	ConfigDir bool   `json:"config_dir"`
	State     bool   `json:"state"`
	Enabled   bool   `json:"enabled"`
	Active    bool   `json:"active"`
	Version   string `json:"version,omitempty"`
}

type switched struct {
	dir       string // StateDir/rollback-*
	was       before
	temps     []string
	committed bool
}

// switchOver saves the current state, then replaces the files by rename and
// restarts the service. The renames are the commit point; an error before
// them leaves everything unchanged (committed false).
func (e *Env) switchOver(s *staged, pr *Probe) (*switched, error) {
	sw := &switched{was: before{
		Bin: exists(e.p(BinPath)), Unit: exists(e.p(UnitPath)), Config: pr.Config, ConfigDir: isDir(e.p(ConfigDir)),
		State: s.stateExisted, Enabled: e.Sys.IsEnabled(UnitName), Active: pr.Active, Version: pr.Installed,
	}}
	undo := func(err error) (*switched, error) {
		for _, t := range sw.temps {
			_ = os.Remove(t)
		}
		if !sw.was.ConfigDir {
			_ = os.RemoveAll(e.p(ConfigDir)) // created by put below
		}
		if sw.dir != "" {
			_ = os.RemoveAll(sw.dir)
		}
		return sw, err
	}
	dir, err := os.MkdirTemp(e.p(StateDir), "rollback-")
	if err != nil {
		return undo(err)
	}
	sw.dir = dir
	if sw.was.Bin {
		if _, err := copyFile(e.p(BinPath), filepath.Join(dir, "aurora3-agent"), 0o755); err != nil {
			return undo(err)
		}
	}
	if sw.was.Unit {
		if _, err := copyFile(e.p(UnitPath), filepath.Join(dir, UnitName), 0o644); err != nil {
			return undo(err)
		}
	}
	b, _ := json.MarshalIndent(sw.was, "", "  ")
	if err := writeSynced(filepath.Join(dir, "before.json"), b, 0o600); err != nil {
		return undo(err)
	}
	if err := e.failAt("save"); err != nil {
		return undo(err)
	}

	// New files go next to their targets first, so the commit is a rename
	// within one directory (one file system).
	put := func(target, src string, data []byte, mode os.FileMode, dirMode os.FileMode) (string, error) {
		if err := os.MkdirAll(filepath.Dir(target), dirMode); err != nil {
			return "", err
		}
		tmp := tempName(target)
		sw.temps = append(sw.temps, tmp)
		if src != "" {
			_, err := copyFile(src, tmp, mode)
			return tmp, err
		}
		return tmp, writeSynced(tmp, data, mode)
	}
	binTmp, err := put(e.p(BinPath), s.bin, nil, 0o755, 0o755)
	if err != nil {
		return undo(err)
	}
	unitTmp, err := put(e.p(UnitPath), "", []byte(Unit), 0o644, 0o755)
	if err != nil {
		return undo(err)
	}
	cfgTmp := ""
	if s.cfg != "" {
		if cfgTmp, err = put(e.p(ConfigPath), s.cfg, nil, 0o600, 0o700); err != nil {
			return undo(err)
		}
	}
	if err := e.failAt("temps"); err != nil {
		return undo(err)
	}

	sw.committed = true
	if err := os.Rename(binTmp, e.p(BinPath)); err != nil {
		return sw, err
	}
	if err := e.failAt("rename-bin"); err != nil {
		return sw, err
	}
	if err := os.Rename(unitTmp, e.p(UnitPath)); err != nil {
		return sw, err
	}
	if cfgTmp != "" {
		if err := os.Rename(cfgTmp, e.p(ConfigPath)); err != nil {
			return sw, err
		}
	}
	for _, d := range []string{BinPath, UnitPath, ConfigPath} {
		syncDir(filepath.Dir(e.p(d)))
	}
	if err := e.Sys.DaemonReload(); err != nil {
		return sw, err
	}
	if err := e.Sys.Enable(UnitName); err != nil {
		return sw, err
	}
	e.Sys.ResetFailed(UnitName)
	if err := e.Sys.Restart(UnitName); err != nil {
		return sw, err
	}
	return sw, e.failAt("restart")
}

// confirm waits until the service answers a pinned Hello on its own port and
// reports version want (D-38: local checks only). An empty want accepts any.
func (e *Env) confirm(c *entry.Config, want string) (*wire.AgentInfo, string, error) {
	deadline := time.Now().Add(e.ConfirmTimeout)
	addr := localAddr(c.Listen)
	cert := filepath.Join(e.p(c.StateDir), "agent.crt")
	var last error
	for {
		if !e.Sys.IsActive(UnitName) {
			last = errors.New("服务没有在运行")
		} else if pin, err := readPin(cert); err != nil {
			last = fmt.Errorf("证书还没有生成：%w", err)
		} else {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			info, err := e.Dial(ctx, addr, pin, c.Token)
			cancel()
			switch {
			case err != nil:
				last = fmt.Errorf("%s 没有应答：%w", addr, err)
			case want != "" && info.Version != want:
				last = fmt.Errorf("%s 上运行的是 %s，不是 %s", addr, info.Version, want)
			default:
				return info, pin, nil
			}
		}
		if time.Now().After(deadline) {
			return nil, "", last
		}
		time.Sleep(e.PollEvery)
	}
}

// rollback puts back what the switch replaced, then checks the machine is as
// before. The rollback directory is deleted only when that check passes
// (D-17).
func (e *Env) rollback(s *staged, sw *switched, cause string) Result {
	e.step("rollback", "start", cause)
	was := sw.was
	var errs []string
	note := func(what string, err error) {
		if err != nil {
			errs = append(errs, what+"："+err.Error())
		}
	}
	for _, t := range sw.temps {
		_ = os.Remove(t)
	}
	// Stopped whenever our unit exists: a crash-looping new version is not
	// "active" but would keep restarting.
	if exists(e.p(UnitPath)) || e.Sys.IsActive(UnitName) {
		note("停止服务", e.Sys.Stop(UnitName))
	}
	// Disable while the unit file still exists, or the symlink would dangle.
	if !was.Enabled && e.Sys.IsEnabled(UnitName) {
		note("取消开机启动", e.Sys.Disable(UnitName))
	}
	note("恢复程序", restore(e.p(BinPath), filepath.Join(sw.dir, "aurora3-agent"), was.Bin, 0o755))
	note("恢复单元", restore(e.p(UnitPath), filepath.Join(sw.dir, UnitName), was.Unit, 0o644))
	if !was.Config {
		if err := os.Remove(e.p(ConfigPath)); err != nil && !errors.Is(err, os.ErrNotExist) {
			note("删除新配置", err)
		}
		if !was.ConfigDir {
			note("删除配置目录", os.RemoveAll(e.p(ConfigDir)))
		}
	}
	note("systemctl daemon-reload", e.Sys.DaemonReload())
	if was.Enabled {
		note("恢复开机启动", e.Sys.Enable(UnitName))
	}
	// The new version may have crash-looped into systemd's start limit.
	e.Sys.ResetFailed(UnitName)
	if was.Active {
		note("启动原来的服务", e.Sys.Restart(UnitName))
	}
	note("恢复", e.failAt("restore"))
	if len(errs) == 0 {
		if was.Active {
			want := was.Version
			if want == "unknown" {
				want = ""
			}
			if _, _, err := e.confirm(s.conf, want); err != nil {
				errs = append(errs, "原来的服务没有恢复："+err.Error())
			}
		} else if e.Sys.IsActive(UnitName) {
			errs = append(errs, "服务仍在运行")
		}
	}
	if len(errs) > 0 {
		msg := strings.Join(errs, "；")
		e.step("rollback", "fail", msg)
		return Result{Result: ResultRollbackFailed, Kept: e.rel(sw.dir),
			Message: cause + "。回滚没有完成（" + msg + "），回滚目录已保留", Previous: was.Version}
	}
	_ = os.RemoveAll(sw.dir)
	_ = os.RemoveAll(s.dir)
	if !was.State {
		// Created by this run: the new agent may have written its
		// certificate and id there.
		_ = os.RemoveAll(e.p(StateDir))
	}
	e.step("rollback", "ok", "")
	return Result{Result: ResultRolledBack, Message: cause + "。已恢复到安装前的状态", Version: was.Version, Previous: was.Version}
}

// restore puts the saved copy back by rename, or removes the file when there
// was none before.
func restore(target, saved string, had bool, mode os.FileMode) error {
	if !had {
		if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	tmp := tempName(target)
	if _, err := copyFile(saved, tmp, mode); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	syncDir(filepath.Dir(target))
	return nil
}

// DirectInfo reads the direct-link parameters of the installed agent (D-4:
// the client reads them over SSH). The token and pin come from the files;
// addresses and the agent id come from the running agent when it answers.
func DirectInfo(e *Env) Result {
	r := e.direct()
	if r.Result == "" {
		r.Result = ResultDirect
	}
	e.emit(r)
	return r
}

func (e *Env) direct() Result {
	if e.ConfirmTimeout <= 0 {
		e.ConfirmTimeout = 30 * time.Second
	}
	c, err := entry.LoadConfig(e.p(ConfigPath))
	if err != nil {
		return Result{Result: ResultRefused, Message: fmt.Sprintf("读取 %s 失败：%v", ConfigPath, err)}
	}
	d := &wire.DirectInfo{Port: portOf(c.Listen), Token: c.Token}
	r := Result{Direct: d}
	if v, err := e.Sys.BinaryVersion(e.p(BinPath)); err == nil {
		r.Version = v
	}
	pin, err := readPin(filepath.Join(e.p(c.StateDir), "agent.crt"))
	if err != nil {
		r.Message = "agent 的证书不存在（agent 还没有启动过）"
		return r
	}
	d.CertSHA256 = pin
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	info, err := e.Dial(ctx, localAddr(c.Listen), pin, c.Token)
	if err != nil {
		r.Message = "agent 没有应答：" + err.Error()
		return r
	}
	r.Running, r.AgentID, r.Version = true, info.ID, info.Version
	d.Addrs = info.Direct.Addrs
	return r
}

func portOf(listen string) int {
	_, p, err := net.SplitHostPort(listen)
	if err == nil {
		if n, err := strconv.Atoi(p); err == nil && n > 0 {
			return n
		}
	}
	return 17710
}

// localAddr is where this machine reaches a listener: loopback for a
// wildcard address.
func localAddr(listen string) string {
	host, _, err := net.SplitHostPort(listen)
	if err != nil {
		host = ""
	}
	switch host {
	case "", "0.0.0.0":
		host = "127.0.0.1"
	case "::":
		host = "::1"
	}
	return net.JoinHostPort(host, strconv.Itoa(portOf(listen)))
}

func osName(path string) string {
	b, err := os.ReadFile(path)
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
				return strings.Trim(v, "\"")
			}
		}
	}
	return runtime.GOOS
}

func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range strings.ToLower(s) {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
