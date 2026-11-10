//go:build linux

package install

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"aurora3/internal/entry"
)

// Uninstall (D-31 to D-34, D-37), run as root over SSH like install:
//
//	aurora3-agent uninstall [--probe] [--force] [--purge]
//
// It first lists the tmux sessions. With sessions and no --force it changes
// nothing and reports them, so the client can ask the user (D-31). The
// default removal stops the service and every aurora3-tmux-* unit and
// deletes the binary and the unit; /etc/aurora3 and /var/lib/aurora3 stay
// (D-32), so a later install keeps the identity and token. --purge also
// deletes those and /usr/local/lib/aurora3 (D-33). Steps run in order; a
// failure stops the run and reports what was done, with no rollback (D-34).
// Only v3 names are touched (D-71).

const ToolsDir = "/usr/local/lib/aurora3"

const (
	ResultUninstalled = "uninstalled" // the steps all ran
	ResultSessions    = "sessions"    // sessions exist and --force was not given: nothing changed
	ResultPartial     = "partial"     // a step failed; Done lists what ran, Failed what did not
)

// UninstallOptions of one run.
type UninstallOptions struct {
	Probe bool // report only
	Force bool // remove even with sessions (the user confirmed, D-31)
	Purge bool // also delete config, identity, state and tools (D-33)
}

// UninstallResult is the last line the command prints.
type UninstallResult struct {
	Result   string   `json:"result"`
	Message  string   `json:"message,omitempty"`
	Sessions []string `json:"sessions"`
	Units    []string `json:"units,omitempty"` // aurora3-tmux-* units found
	Present  []string `json:"present"`         // v3 paths on the machine before the run
	Done     []string `json:"done,omitempty"`
	Failed   string   `json:"failed,omitempty"`
	Kept     []string `json:"kept,omitempty"` // left in place by a default uninstall
}

// UninstallExitCode of the command for a result.
func UninstallExitCode(r UninstallResult) int {
	switch r.Result {
	case ResultProbe, ResultUninstalled:
		return 0
	case ResultPartial:
		return 4
	}
	return 1
}

// Uninstall removes aurora3-agent, printing progress and the result.
func Uninstall(e *Env, o UninstallOptions) UninstallResult {
	r := e.uninstall(o)
	e.emit(r)
	return r
}

func (e *Env) uninstall(o UninstallOptions) UninstallResult {
	if err := e.checkInstance(); err != nil {
		return UninstallResult{Result: ResultRefused, Message: err.Error()}
	}
	if !o.Probe {
		unlock, err := lock(e.p(LockPath))
		if err != nil {
			return UninstallResult{Result: ResultRefused, Message: err.Error()}
		}
		defer unlock()
	}
	e.step("probe", "start", "")
	r := UninstallResult{Sessions: []string{}, Present: []string{}}
	if err := e.Sys.Available(); err != nil {
		e.step("probe", "fail", err.Error())
		r.Result, r.Message = ResultRefused, err.Error()
		return r
	}
	for _, p := range []string{e.lay().Bin, e.lay().UnitPath, e.lay().ConfigDir, e.lay().StateDir, ToolsDir} {
		if exists(e.p(p)) {
			r.Present = append(r.Present, p)
		}
	}
	sessions, err := e.Sys.TmuxSessions(e.p(e.lay().StateDir))
	if err != nil {
		e.step("probe", "fail", err.Error())
		r.Result, r.Message = ResultRefused, "无法列出终端会话："+err.Error()
		return r
	}
	r.Sessions = append(r.Sessions, sessions...)
	r.Units = e.Sys.Units(e.lay().TmuxPattern)
	e.step("probe", "ok", "")
	if o.Probe {
		r.Result = ResultProbe
		return r
	}
	if len(r.Present) == 0 && len(r.Units) == 0 {
		r.Result, r.Message = ResultUninstalled, "这台机器上没有 aurora3-agent"
		return r
	}
	if len(r.Sessions) > 0 && !o.Force {
		r.Result = ResultSessions
		r.Message = fmt.Sprintf("还有 %d 个终端会话在运行，卸载会结束它们：%s", len(r.Sessions), strings.Join(r.Sessions, "、"))
		return r
	}

	steps := []struct {
		name string
		run  func() error
	}{
		{"stop-agent", func() error {
			if !exists(e.p(e.lay().UnitPath)) && !e.Sys.IsActive(e.lay().UnitName) {
				return nil
			}
			if err := e.Sys.Stop(e.lay().UnitName); err != nil {
				return err
			}
			if e.Sys.IsEnabled(e.lay().UnitName) {
				return e.Sys.Disable(e.lay().UnitName)
			}
			return nil
		}},
		// Explicitly, so no tmux server (and no shell in it) is left running
		// with nothing to manage it (D-37).
		{"stop-sessions", func() error {
			var errs []string
			for _, u := range e.Sys.Units(e.lay().TmuxPattern) {
				if err := e.Sys.Stop(u); err != nil {
					errs = append(errs, err.Error())
				}
			}
			// A tmux server started outside a unit (the agent run by hand).
			if err := e.Sys.KillTmux(e.p(e.lay().StateDir)); err != nil {
				errs = append(errs, err.Error())
			}
			if left := e.Sys.Units(e.lay().TmuxPattern); len(left) > 0 {
				errs = append(errs, "仍在运行："+strings.Join(left, " "))
			}
			if len(errs) > 0 {
				return errors.New(strings.Join(errs, "；"))
			}
			return nil
		}},
		{"remove-unit", func() error {
			if err := removeIfExists(e.p(e.lay().UnitPath)); err != nil {
				return err
			}
			if err := e.Sys.DaemonReload(); err != nil {
				return err
			}
			e.Sys.ResetFailed(e.lay().UnitName)
			return nil
		}},
		{"remove-binary", func() error { return removeIfExists(e.p(e.lay().Bin)) }},
	}
	if o.Purge {
		steps = append(steps,
			struct {
				name string
				run  func() error
			}{"purge", func() error {
				for _, d := range []string{e.lay().ConfigDir, e.lay().StateDir, ToolsDir} {
					// The tools directory is shared by every instance; only the
					// default instance owns it.
					if d == ToolsDir && e.lay().Instance != "" {
						continue
					}
					if err := os.RemoveAll(e.p(d)); err != nil {
						return err
					}
				}
				if e.lay().Instance != "" { // the parents, when no other instance is left in them
					_ = os.Remove(e.p(entry.InstancesConfigDir))
					_ = os.Remove(e.p(entry.InstancesStateDir))
				}
				return nil
			}})
	}
	for _, s := range steps {
		e.step(s.name, "start", "")
		err := s.run()
		if err == nil {
			err = e.failAt("uninstall-" + s.name)
		}
		if err != nil {
			e.step(s.name, "fail", err.Error())
			r.Result, r.Failed = ResultPartial, s.name
			r.Message = fmt.Sprintf("卸载在“%s”这一步失败：%v。已完成：%s。没有回滚，可以重试", stepLabel(s.name), err, labels(r.Done))
			return r
		}
		e.step(s.name, "ok", "")
		r.Done = append(r.Done, s.name)
	}
	r.Result = ResultUninstalled
	if !o.Purge {
		for _, d := range []string{e.lay().ConfigDir, e.lay().StateDir} {
			if exists(e.p(d)) {
				r.Kept = append(r.Kept, d)
			}
		}
	}
	return r
}

func removeIfExists(p string) error {
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

var stepLabels = map[string]string{
	"stop-agent":    "停止 agent",
	"stop-sessions": "结束终端会话",
	"remove-unit":   "删除 systemd 单元",
	"remove-binary": "删除程序",
	"purge":         "删除配置与状态",
}

func stepLabel(s string) string {
	if l, ok := stepLabels[s]; ok {
		return l
	}
	return s
}

func labels(steps []string) string {
	if len(steps) == 0 {
		return "无"
	}
	out := make([]string, len(steps))
	for i, s := range steps {
		out[i] = stepLabel(s)
	}
	return strings.Join(out, "、")
}
