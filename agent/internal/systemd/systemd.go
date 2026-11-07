//go:build linux

// Package systemd serves the "systemd" service: the unit list, a unit's status,
// and start/stop/restart for the units the agent's allowlist names (D-28, D-45).
package systemd

import (
	"context"
	"encoding/json"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

// Env is what the systemd service needs from the agent: the allowlist and the
// audit writer (D-26). Actions returns the allowlist as agent.json holds it
// now; it is a function because the entry changes it at run time
// (agent.actions, D-28), and services do not reach into the entry (D-40).
type Env struct {
	Actions func() map[string][]string
	Audit   Auditor
}

type Auditor interface {
	Write(event string, fields map[string]any)
}

func (s *Env) allowed(unit string) []string {
	if s.Actions == nil {
		return nil
	}
	if a := s.Actions()[unit]; a != nil {
		return a
	}
	return nil
}

type svcArgs struct {
	Name   string `json:"name"`
	Action string `json:"action"`
	Lines  int    `json:"lines"`
}

// unit is one row of svc.list.
type unit struct {
	Name        string   `json:"name"`
	Load        string   `json:"load"`
	Active      string   `json:"active"`
	Sub         string   `json:"sub"`
	Description string   `json:"description"`
	File        string   `json:"file,omitempty"` // enabled | disabled | static | masked ...
	Allowed     []string `json:"allowed_actions,omitempty"`
}

// svcList lists the service units systemd knows (loaded ones, any state),
// with their unit-file state and the actions the allowlist permits.
func (s *Env) svcList(ctx context.Context, _ json.RawMessage) (any, error) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, "systemctl", "list-units", "--type=service", "--all", "--plain", "--no-legend", "--no-pager").Output()
	if err != nil {
		return nil, wire.Errf(wire.CodeInternal, "systemctl list-units 失败：%v", err)
	}
	files, _ := exec.CommandContext(cctx, "systemctl", "list-unit-files", "--type=service", "--plain", "--no-legend", "--no-pager").Output()
	list := parseUnits(string(out), parseUnitFiles(string(files)))
	for i := range list {
		list[i].Allowed = s.allowed(list[i].Name)
	}
	return map[string]any{"units": list}, nil
}

// parseUnits reads `systemctl list-units --plain --no-legend`: UNIT LOAD
// ACTIVE SUB DESCRIPTION, the description being the rest of the line.
func parseUnits(text string, fileState map[string]string) []unit {
	list := []unit{}
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 || paths.CheckUnit(f[0]) != nil {
			continue
		}
		u := unit{Name: f[0], Load: f[1], Active: f[2], Sub: f[3], File: fileState[f[0]]}
		if len(f) > 4 {
			u.Description = strings.Join(f[4:], " ")
		}
		list = append(list, u)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	return list
}

// parseUnitFiles reads `systemctl list-unit-files --plain --no-legend`: UNIT
// STATE [PRESET].
func parseUnitFiles(text string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		if f := strings.Fields(line); len(f) >= 2 {
			out[f[0]] = f[1]
		}
	}
	return out
}

func (s *Env) svcInfo(ctx context.Context, raw json.RawMessage) (any, error) {
	var a svcArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := paths.CheckUnit(a.Name); err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	out, _ := exec.CommandContext(cctx, "systemctl", "show", a.Name, "--no-pager", "--property=ActiveState,SubState,Description,LoadState,MainPID,ActiveEnterTimestamp,UnitFileState,FragmentPath").Output()
	v := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		if k, val, ok := strings.Cut(line, "="); ok {
			v[k] = val
		}
	}
	allowed := s.allowed(a.Name)
	if allowed == nil {
		allowed = []string{}
	}
	return map[string]any{"name": a.Name, "active": v["ActiveState"], "state": v["SubState"], "description": v["Description"],
		"load": v["LoadState"], "pid": atoi64(v["MainPID"]), "since": v["ActiveEnterTimestamp"], "file": v["UnitFileState"],
		"path": v["FragmentPath"], "allowed_actions": allowed}, nil
}

// validAction: the actions an allowlist may name (paths.ServiceActions, the
// same list the entry checks agent.actions against).
func validAction(a string) bool {
	for _, x := range paths.ServiceActions {
		if x == a {
			return true
		}
	}
	return false
}

func (s *Env) svcAction(ctx context.Context, raw json.RawMessage) (any, error) {
	var a svcArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := paths.CheckUnit(a.Name); err != nil {
		return nil, err
	}
	if !validAction(a.Action) {
		return nil, wire.Errf(wire.CodeBadRequest, "服务操作无效")
	}
	permitted := false
	for _, x := range s.allowed(a.Name) {
		permitted = permitted || x == a.Action
	}
	if !permitted {
		return nil, wire.Errf(wire.CodeForbidden, "未授权的服务操作：请先在服务详情里允许“%s”", a.Action)
	}
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, "systemctl", a.Action, a.Name).CombinedOutput()
	s.Audit.Write("svc."+a.Action, map[string]any{"name": a.Name, "ok": err == nil})
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if len(msg) > 300 {
			msg = msg[len(msg)-300:]
		}
		return nil, wire.Errf(wire.CodeInternal, "服务操作失败：%s", msg)
	}
	return s.svcInfo(ctx, raw)
}

// decode reads the operation's arguments (copied from v2 server.go).
func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

// atoi64 parses an integer field from a systemctl or /proc line (v2 monitor.go).
func atoi64(s string) int64 { n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64); return n }
