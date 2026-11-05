package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type fake struct {
	id   string
	ops  []string
	deps []Dependency
	ran  *int
}

func (f fake) ID() string { return f.id }
func (f fake) Operations() []Operation {
	out := make([]Operation, 0, len(f.ops))
	for _, name := range f.ops {
		name := name
		out = append(out, Operation{Name: name, Handle: func(context.Context, json.RawMessage) (any, error) {
			if f.ran != nil {
				*f.ran++
			}
			return name, nil
		}})
	}
	return out
}
func (f fake) Dependencies() []Dependency { return f.deps }

func found(string) error { return nil }

func TestDisabledServiceRefusesWithoutRunningHandler(t *testing.T) {
	ran := 0
	r, err := NewRegistry([]Service{fake{id: "files", ops: []string{"fs.list"}, ran: &ran}}, map[string]bool{"files": false}, found)
	if err != nil {
		t.Fatal(err)
	}
	_, err = r.Dispatch(context.Background(), "fs.list", nil)
	if !errors.Is(err, ErrDisabled) {
		t.Fatalf("disabled service: got %v, want ErrDisabled", err)
	}
	if ran != 0 {
		t.Fatalf("handler ran %d times while its service was off", ran)
	}
}

func TestEnabledByDefault(t *testing.T) {
	r, err := NewRegistry([]Service{fake{id: "git", ops: []string{"git.status"}}}, nil, found)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Enabled("git") {
		t.Fatal("a service missing from agent.json must default to on (D-9)")
	}
	got, err := r.Dispatch(context.Background(), "git.status", nil)
	if err != nil || got != "git.status" {
		t.Fatalf("dispatch: %v %v", got, err)
	}
}

func TestMissingRequiredDependencyMarksUnavailable(t *testing.T) {
	deps := []Dependency{{Name: "nvidia-smi", Purpose: "GPU 监控", Required: true}}
	missing := func(name string) error {
		if name == "nvidia-smi" {
			return errors.New("not found")
		}
		return nil
	}
	r, err := NewRegistry([]Service{fake{id: "monitor", ops: []string{"gpu.info"}, deps: deps}}, nil, missing)
	if err != nil {
		t.Fatal(err)
	}
	st := r.Statuses()[0]
	if st.Available || !strings.Contains(st.Reason, "nvidia-smi") {
		t.Fatalf("status = %+v, want unavailable with the program named", st)
	}
	_, err = r.Dispatch(context.Background(), "gpu.info", nil)
	if !errors.Is(err, ErrUnavailable) || !strings.Contains(err.Error(), "nvidia-smi") {
		t.Fatalf("dispatch: %v, want ErrUnavailable naming nvidia-smi", err)
	}
}

func TestOptionalDependencyDoesNotDisable(t *testing.T) {
	deps := []Dependency{{Name: "journalctl", Purpose: "日志", Required: false}}
	none := func(string) error { return errors.New("not found") }
	r, _ := NewRegistry([]Service{fake{id: "monitor", ops: []string{"log.tail"}, deps: deps}}, nil, none)
	if !r.Statuses()[0].Available {
		t.Fatal("a missing optional program must not make the service unavailable")
	}
}

func TestEntryOperationsCannotBeSwitchedOff(t *testing.T) {
	r, _ := NewRegistry([]Service{fake{id: "files", ops: []string{"fs.list"}}}, map[string]bool{"files": false}, found)
	if err := r.AddEntry("agent.info", func(context.Context, json.RawMessage) (any, error) { return "info", nil }); err != nil {
		t.Fatal(err)
	}
	got, err := r.Dispatch(context.Background(), "agent.info", nil)
	if err != nil || got != "info" {
		t.Fatalf("entry operation refused: %v %v (D-46)", got, err)
	}
}

func TestSetEnabledTakesEffectAtOnce(t *testing.T) {
	ran := 0
	r, _ := NewRegistry([]Service{fake{id: "net", ops: []string{"net.dial"}, ran: &ran}}, nil, found)
	if err := r.SetEnabled("net", false); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Dispatch(context.Background(), "net.dial", nil); !errors.Is(err, ErrDisabled) {
		t.Fatalf("after switching off: %v", err)
	}
	if err := r.SetEnabled("net", true); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Dispatch(context.Background(), "net.dial", nil); err != nil {
		t.Fatalf("after switching on: %v", err)
	}
	if ran != 1 {
		t.Fatalf("handler ran %d times, want 1", ran)
	}
}

func TestUnknownOperationAndService(t *testing.T) {
	r, _ := NewRegistry([]Service{fake{id: "files", ops: []string{"fs.list"}}}, nil, found)
	if _, err := r.Dispatch(context.Background(), "fs.nope", nil); err == nil {
		t.Fatal("unknown operation must fail")
	}
	if _, err := NewRegistry([]Service{fake{id: "files"}}, map[string]bool{"fles": true}, found); err == nil {
		t.Fatal("a switch naming an unknown service must fail, not be ignored")
	}
	if err := r.SetEnabled("nope", true); err == nil {
		t.Fatal("SetEnabled on an unknown service must fail")
	}
}

func TestDuplicateOperationRejected(t *testing.T) {
	_, err := NewRegistry([]Service{fake{id: "a", ops: []string{"x.y"}}, fake{id: "b", ops: []string{"x.y"}}}, nil, found)
	if err == nil {
		t.Fatal("one operation provided by two services must fail")
	}
}

func TestStatusesSortedAndListOperations(t *testing.T) {
	r, _ := NewRegistry([]Service{
		fake{id: "terminal", ops: []string{"session.list", "terminal"}},
		fake{id: "files", ops: []string{"fs.list"}},
	}, nil, found)
	st := r.Statuses()
	if st[0].ID != "files" || st[1].ID != "terminal" {
		t.Fatalf("statuses not sorted by ID: %+v", st)
	}
	if strings.Join(st[1].Ops, ",") != "session.list,terminal" {
		t.Fatalf("operations: %v", st[1].Ops)
	}
}
