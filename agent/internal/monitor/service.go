//go:build linux

package monitor

import "aurora3/internal/service"

// Service is the "monitor" service (D-45). gpu.info is added once the terminal
// service provides the session lookup it needs.
func (s *Env) Service() service.Service {
	if s.sampler == nil {
		s.sampler = newProcSampler()
	}
	return svc{s}
}

type svc struct{ e *Env }

func (svc) ID() string { return "monitor" }

func (svc) Dependencies() []service.Dependency {
	return []service.Dependency{{Name: "journalctl", Purpose: "log.tail 读取服务日志", Required: false}}
}

func (v svc) Operations() []service.Operation {
	e := v.e
	return []service.Operation{
		{Name: "sys.metrics", Handle: e.sysMetrics},
		{Name: "proc.list", Handle: e.procList},
		{Name: "log.tail", Handle: e.logTail},
	}
}
