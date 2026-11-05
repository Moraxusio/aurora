// Package service defines the agent's service layer (D-40 to D-46). The agent
// is an entry point; everything a client can call is an operation that belongs
// to exactly one service, or to the entry itself.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
)

// Handler serves one operation. A unary operation returns a result; a stream
// operation is served by a StreamHandler.
type Handler func(ctx context.Context, args json.RawMessage) (any, error)

// Operation is one named call a service provides.
type Operation struct {
	Name   string
	Handle Handler
}

// Dependency is an external program a service needs on the machine.
type Dependency struct {
	Name     string `json:"name"`
	Purpose  string `json:"purpose"`
	Required bool   `json:"required"`
}

// Service is one switchable feature. Its ID is a stable English name used in
// agent.json and on the wire (D-41, D-46).
type Service interface {
	ID() string
	Operations() []Operation
	Dependencies() []Dependency
}

// Status is what agent.info reports about a service (D-42).
type Status struct {
	ID        string   `json:"id"`
	Enabled   bool     `json:"enabled"`
	Available bool     `json:"available"`
	Reason    string   `json:"reason,omitempty"`
	Ops       []string `json:"ops"`
}

// ErrDisabled is returned for an operation whose service is switched off (D-44).
var ErrDisabled = errors.New("service disabled")

// ErrUnavailable is returned for an operation whose service is missing a
// required dependency (D-43).
var ErrUnavailable = errors.New("service unavailable")

// Registry holds the fixed service list and the operation table built from it.
type Registry struct {
	services map[string]Service
	enabled  map[string]bool
	ops      map[string]string // operation name -> service ID; "" means the entry
	entry    map[string]Handler
	lookPath func(string) error
}

// NewRegistry builds a registry. enabled holds the switches from agent.json;
// a service missing from it is on (D-9). lookPath reports whether a program
// exists; a missing required program marks its service unavailable (D-43).
func NewRegistry(list []Service, enabled map[string]bool, lookPath func(string) error) (*Registry, error) {
	r := &Registry{
		services: map[string]Service{},
		enabled:  map[string]bool{},
		ops:      map[string]string{},
		entry:    map[string]Handler{},
		lookPath: lookPath,
	}
	for _, s := range list {
		id := s.ID()
		if _, dup := r.services[id]; dup {
			return nil, fmt.Errorf("service %q registered twice", id)
		}
		r.services[id] = s
		on, set := enabled[id]
		r.enabled[id] = !set || on
		for _, op := range s.Operations() {
			if _, dup := r.ops[op.Name]; dup {
				return nil, fmt.Errorf("operation %q provided by two services", op.Name)
			}
			r.ops[op.Name] = id
			r.entry[op.Name] = op.Handle
		}
	}
	for id := range enabled {
		if _, ok := r.services[id]; !ok {
			return nil, fmt.Errorf("agent.json names unknown service %q", id)
		}
	}
	return r, nil
}

// AddEntry registers an operation that belongs to the entry itself. Entry
// operations cannot be switched off (D-46).
func (r *Registry) AddEntry(name string, h Handler) error {
	if _, dup := r.ops[name]; dup {
		return fmt.Errorf("operation %q already registered", name)
	}
	r.ops[name] = ""
	r.entry[name] = h
	return nil
}

// Dispatch runs an operation. It refuses an operation whose service is off
// (D-44) or unavailable (D-43), before the handler runs.
func (r *Registry) Dispatch(ctx context.Context, name string, args json.RawMessage) (any, error) {
	id, ok := r.ops[name]
	if !ok {
		return nil, fmt.Errorf("unsupported operation %q", name)
	}
	if id != "" {
		if !r.enabled[id] {
			return nil, fmt.Errorf("%w: %s", ErrDisabled, id)
		}
		if st := r.status(id); !st.Available {
			return nil, fmt.Errorf("%w: %s: %s", ErrUnavailable, id, st.Reason)
		}
	}
	return r.entry[name](ctx, args)
}

// SetEnabled changes a switch at run time. The caller writes agent.json and
// the audit log (D-26); the registry only enforces the switch (D-44).
func (r *Registry) SetEnabled(id string, on bool) error {
	if _, ok := r.services[id]; !ok {
		return fmt.Errorf("unknown service %q", id)
	}
	r.enabled[id] = on
	return nil
}

// Enabled reports whether a service switch is on.
func (r *Registry) Enabled(id string) bool { return r.enabled[id] }

// Statuses reports every service, sorted by ID (D-42).
func (r *Registry) Statuses() []Status {
	ids := make([]string, 0, len(r.services))
	for id := range r.services {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]Status, 0, len(ids))
	for _, id := range ids {
		out = append(out, r.status(id))
	}
	return out
}

func (r *Registry) status(id string) Status {
	s := r.services[id]
	st := Status{ID: id, Enabled: r.enabled[id], Available: true}
	for _, op := range s.Operations() {
		st.Ops = append(st.Ops, op.Name)
	}
	sort.Strings(st.Ops)
	for _, d := range s.Dependencies() {
		if !d.Required || r.lookPath == nil {
			continue
		}
		if err := r.lookPath(d.Name); err != nil {
			st.Available = false
			st.Reason = d.Name + " not found: " + d.Purpose
			break
		}
	}
	return st
}
