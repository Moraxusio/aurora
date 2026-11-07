package netfwd

import "aurora3/internal/service"

// ID is the service name in agent.json and on the wire (D-41, D-45).
const ID = "net"

// Service is the "net" service: listening ports and port forwarding.
func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ e *Env }

func (svc) ID() string                         { return ID }
func (svc) Dependencies() []service.Dependency { return nil }

func (v svc) Operations() []service.Operation {
	return []service.Operation{
		{Name: "net.ports", Handle: v.e.netPorts},
		{Name: "net.dial", Stream: v.e.netDial},
	}
}
