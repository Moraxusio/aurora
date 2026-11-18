//go:build linux

package systemd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"aurora3/internal/wire"
)

type noAudit struct{}

func (noAudit) Write(string, map[string]any) {}

const unitsSample = `ssh.service                loaded active   running OpenBSD Secure Shell server
snapd.service              loaded inactive dead    Snap Daemon
foo@1.service              not-found inactive dead    foo@1.service
-bad.service               loaded active   running looks like a flag
`

const filesSample = `ssh.service     enabled  enabled
snapd.service   disabled enabled
motd.service    static   -
`

func TestParseUnits(t *testing.T) {
	list := parseUnits(unitsSample, parseUnitFiles(filesSample))
	if len(list) != 3 {
		t.Fatalf("want 3 units (the flag-like name left out), got %+v", list)
	}
	// sorted by name
	if list[0].Name != "foo@1.service" || list[1].Name != "snapd.service" || list[2].Name != "ssh.service" {
		t.Fatalf("order: %+v", list)
	}
	ssh := list[2]
	if ssh.Load != "loaded" || ssh.Active != "active" || ssh.Sub != "running" || ssh.Description != "OpenBSD Secure Shell server" || ssh.File != "enabled" {
		t.Fatalf("ssh: %+v", ssh)
	}
	if list[1].File != "disabled" || list[0].File != "" {
		t.Fatalf("unit file states: %+v", list)
	}
}

// svc.action runs only what the allowlist names, and the allowlist is read on
// every call (a change made with agent.actions applies at once).
func TestActionNeedsAllowlist(t *testing.T) {
	actions := map[string][]string{}
	e := &Env{Actions: func() map[string][]string { return actions }, Audit: noAudit{}}
	args := func(name, action string) json.RawMessage {
		b, _ := json.Marshal(map[string]string{"name": name, "action": action})
		return b
	}
	_, err := e.svcAction(context.Background(), args("nginx.service", "restart"))
	if wire.CodeOf(err) != wire.CodeForbidden {
		t.Fatalf("not allowed yet: %v", err)
	}
	actions["nginx.service"] = []string{"start"}
	if _, err := e.svcAction(context.Background(), args("nginx.service", "restart")); wire.CodeOf(err) != wire.CodeForbidden {
		t.Fatalf("restart is not on the list: %v", err)
	}
	for _, bad := range []struct{ n, a string }{{"nginx.service", "enable"}, {"-x", "start"}, {"nginx.service", ""}} {
		if _, err := e.svcAction(context.Background(), args(bad.n, bad.a)); wire.CodeOf(err) != wire.CodeBadRequest {
			t.Fatalf("%+v: %v", bad, err)
		}
	}
}

// With no Actions function (a service built without an entry) nothing is
// allowed, instead of panicking.
func TestNoActionsFunction(t *testing.T) {
	e := &Env{Audit: noAudit{}}
	b, _ := json.Marshal(map[string]string{"name": "x.service", "action": "start"})
	if _, err := e.svcAction(context.Background(), b); wire.CodeOf(err) != wire.CodeForbidden {
		t.Fatalf("%v", err)
	}
}

func TestInfoFailureIsNotAnEmptySuccess(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte("#!/bin/sh\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	e := &Env{}
	if result, err := e.svcInfo(context.Background(), json.RawMessage(`{"name":"fixture.service"}`)); err == nil || result != nil {
		t.Fatalf("failed status query reported success: %v, %v", result, err)
	}
}

func TestConcurrentActionIsRejectedBeforeExecuting(t *testing.T) {
	e := &Env{
		Actions: func() map[string][]string { return map[string][]string{"fixture.service": {"restart"}} },
		busy:    map[string]bool{"fixture.service": true},
	}
	t.Setenv("PATH", t.TempDir())
	_, err := e.svcAction(context.Background(), json.RawMessage(`{"name":"fixture.service","action":"restart"}`))
	if wire.CodeOf(err) != wire.CodeConflict {
		t.Fatalf("expected busy rejection without invoking systemctl: %v", err)
	}
	delete(e.busy, "fixture.service")
	_, err = e.svcAction(context.Background(), json.RawMessage(`{"name":"fixture.service","action":"restart"}`))
	if wire.CodeOf(err) != wire.CodeInternal || e.busy["fixture.service"] {
		t.Fatalf("failed action must release its lease: %v, %+v", err, e.busy)
	}
}
