// Package service defines the agent's service layer (D-40 to D-46). The agent
// is an entry point; everything a client can call is an operation that belongs
// to exactly one service, or to the entry itself.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"sync"
)

// Handler serves one unary operation: it returns a result.
type Handler func(ctx context.Context, args json.RawMessage) (any, error)

// StreamHandler serves one stream operation (upload, download, terminal):
// it owns the stream and writes its own frames.
type StreamHandler func(ctx context.Context, st net.Conn, args json.RawMessage) error

// Operation is one named call a service provides. Exactly one of Handle and
// Stream is set.
type Operation struct {
	Name   string
	Handle Handler
	Stream StreamHandler
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
// Dispatch runs on many streams at once while a switch may change, so the
// switches are guarded; the tables are fixed after NewRegistry and AddEntry.
type Registry struct {
	mu       sync.RWMutex
	services map[string]Service
	enabled  map[string]bool
	ops      map[string]string // operation name -> service ID; "" means the entry
	entry    map[string]Handler
	streams  map[string]StreamHandler
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
		streams:  map[string]StreamHandler{},
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
			if (op.Handle == nil) == (op.Stream == nil) {
				return nil, fmt.Errorf("operation %q must have exactly one of Handle and Stream", op.Name)
			}
			r.ops[op.Name] = id
			if op.Stream != nil {
				r.streams[op.Name] = op.Stream
			} else {
				r.entry[op.Name] = op.Handle
			}
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
// operations cannot be switched off (D-46). Call it before serving.
func (r *Registry) AddEntry(name string, h Handler) error {
	if _, dup := r.ops[name]; dup {
		return fmt.Errorf("operation %q already registered", name)
	}
	r.ops[name] = ""
	r.entry[name] = h
	return nil
}

// EntryOps lists the operations that belong to the entry (D-46), sorted.
func (r *Registry) EntryOps() []string {
	var out []string
	for name, id := range r.ops {
		if id == "" {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// ErrUnknown is returned for an operation no service provides.
var ErrUnknown = errors.New("unsupported operation")

// Check reports whether operation name may run now: it exists, and its
// service is on (D-44) and available (D-43). It returns the service ID ("" for
// the entry) and whether the operation is a stream.
func (r *Registry) Check(name string) (id string, stream bool, err error) {
	id, ok := r.ops[name]
	if !ok {
		return "", false, fmt.Errorf("%w: %s", ErrUnknown, name)
	}
	_, stream = r.streams[name]
	if id != "" {
		r.mu.RLock()
		on := r.enabled[id]
		r.mu.RUnlock()
		if !on {
			return id, stream, fmt.Errorf("%w: %s", ErrDisabled, id)
		}
		if st := r.status(id); !st.Available {
			return id, stream, fmt.Errorf("%w: %s: %s", ErrUnavailable, id, st.Reason)
		}
	}
	return id, stream, nil
}

// Dispatch runs a unary operation. It refuses an operation whose service is
// off (D-44) or unavailable (D-43), before the handler runs.
func (r *Registry) Dispatch(ctx context.Context, name string, args json.RawMessage) (any, error) {
	_, stream, err := r.Check(name)
	if err != nil {
		return nil, err
	}
	if stream {
		return nil, fmt.Errorf("%w: %s is a stream operation", ErrUnknown, name)
	}
	return r.entry[name](ctx, args)
}

// DispatchStream runs a stream operation, with the same refusals as Dispatch.
func (r *Registry) DispatchStream(ctx context.Context, name string, st net.Conn, args json.RawMessage) error {
	_, stream, err := r.Check(name)
	if err != nil {
		return err
	}
	if !stream {
		return fmt.Errorf("%w: %s is a unary operation", ErrUnknown, name)
	}
	return r.streams[name](ctx, st, args)
}

// SetEnabled changes a switch at run time. The caller writes agent.json and
// the audit log (D-26); the registry only enforces the switch (D-44).
func (r *Registry) SetEnabled(id string, on bool) error {
	if _, ok := r.services[id]; !ok {
		return fmt.Errorf("unknown service %q", id)
	}
	r.mu.Lock()
	was := r.enabled[id]
	r.enabled[id] = on
	r.mu.Unlock()
	if sw, ok := r.services[id].(Switchable); ok && was != on {
		sw.Switched(on)
	}
	return nil
}

// Switchable is implemented by a service that must act when it is switched
// at run time, such as terminal disconnecting attached windows (D-51). The
// registry has already refused new operations when Switched(false) runs.
type Switchable interface {
	Switched(on bool)
}

// Enabled reports whether a service switch is on.
func (r *Registry) Enabled(id string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.enabled[id]
}

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
	st := Status{ID: id, Enabled: r.Enabled(id), Available: true}
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
