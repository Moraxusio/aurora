//go:build linux

package monitor

import "aurora3/internal/service"

// Service is the "monitor" service (D-45, D-118).
func (s *Env) Service() service.Service {
	if s.sampler == nil {
		s.sampler = newProcSampler()
	}
	return svc{s}
}

type svc struct{ e *Env }

func (svc) ID() string { return "monitor" }

func (svc) Dependencies() []service.Dependency {
	return []service.Dependency{
		{Name: "journalctl", Purpose: "log.tail 读取服务日志", Required: false},
		{Name: "nvidia-smi", Purpose: "gpu.info 读取 NVIDIA GPU 状态", Required: false},
	}
}

func (v svc) Operations() []service.Operation {
	e := v.e
	return []service.Operation{
		{Name: "sys.metrics", Handle: e.sysMetrics},
		{Name: "gpu.info", Handle: e.gpuInfo},
		{Name: "proc.list", Handle: e.procList},
		{Name: "log.tail", Handle: e.logTail},
	}
}
