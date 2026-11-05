//go:build linux

// Package systemd serves the "systemd" service: service status and start/stop/restart
// for the units the agent's allowlist names (D-28, D-45).
package systemd

import (
	"context"
	"encoding/json"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

// Env is what the systemd service needs from the agent: the allowlist from
// agent.json and the audit writer (D-26).
type Env struct {
	ServiceActions map[string][]string
	Audit          Auditor
}

type Auditor interface {
	Write(event string, fields map[string]any)
}


type svcArgs struct {
	Name   string `json:"name"`
	Action string `json:"action"`
	Lines  int    `json:"lines"`
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
	out, _ := exec.CommandContext(cctx, "systemctl", "show", a.Name, "--no-pager", "--property=ActiveState,SubState,Description,LoadState,MainPID,ActiveEnterTimestamp").Output()
	v := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		if k, val, ok := strings.Cut(line, "="); ok {
			v[k] = val
		}
	}
	allowed := s.ServiceActions[a.Name]
	return map[string]any{"name": a.Name, "active": v["ActiveState"], "state": v["SubState"], "description": v["Description"],
		"load": v["LoadState"], "pid": atoi64(v["MainPID"]), "since": v["ActiveEnterTimestamp"], "allowed_actions": allowed}, nil
}

func (s *Env) svcAction(ctx context.Context, raw json.RawMessage) (any, error) {
	var a svcArgs
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if err := paths.CheckUnit(a.Name); err != nil {
		return nil, err
	}
	if a.Action != "start" && a.Action != "stop" && a.Action != "restart" {
		return nil, wire.Errf(wire.CodeBadRequest, "服务操作无效")
	}
	permitted := false
	for _, x := range s.ServiceActions[a.Name] {
		permitted = permitted || x == a.Action
	}
	if !permitted {
		return nil, wire.Errf(wire.CodeForbidden, "未授权的服务操作：请在 agent.json 的 service_actions 中授权")
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
