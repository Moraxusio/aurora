//go:build linux

package systemd

import "aurora3/internal/service"

// Service is the "systemd" service (D-45): unit status and the allowlisted
// start/stop/restart (D-28).
func (s *Env) Service() service.Service { return svc{s} }

type svc struct{ e *Env }

func (svc) ID() string { return "systemd" }

func (svc) Dependencies() []service.Dependency {
	return []service.Dependency{{Name: "systemctl", Purpose: "查看和启停 systemd 服务", Required: true}}
}

func (v svc) Operations() []service.Operation {
	e := v.e
	return []service.Operation{
		{Name: "svc.info", Handle: e.svcInfo},
		{Name: "svc.action", Handle: e.svcAction},
	}
}
