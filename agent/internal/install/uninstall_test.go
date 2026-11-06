//go:build linux

package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func (r *rig) uninstall(o UninstallOptions) UninstallResult {
	return Uninstall(r.env("", "3.0.1"), o)
}

func TestUninstallDefaultKeepsConfigAndState(t *testing.T) {
	r := newRig(t)
	inst := r.install("3.0.1", false, "")
	cfg, _ := os.ReadFile(filepath.Join(r.root, ConfigPath))
	res := r.uninstall(UninstallOptions{})
	if res.Result != ResultUninstalled || UninstallExitCode(res) != 0 {
		t.Fatalf("%+v", res)
	}
	if exists(filepath.Join(r.root, BinPath)) || exists(filepath.Join(r.root, UnitPath)) {
		t.Fatal("binary or unit left")
	}
	if r.sys.active || r.sys.enabled {
		t.Fatal(r.sysState())
	}
	if strings.Join(res.Kept, ",") != ConfigDir+","+StateDir {
		t.Fatalf("kept %v", res.Kept)
	}
	if b, _ := os.ReadFile(filepath.Join(r.root, ConfigPath)); string(b) != string(cfg) {
		t.Fatal("agent.json changed")
	}
	// A later install keeps the token and the certificate (D-32).
	again := r.install("3.0.1", false, "")
	if again.Result != ResultInstalled || again.Direct.Token != inst.Direct.Token || again.Direct.CertSHA256 != inst.Direct.CertSHA256 {
		t.Fatalf("reinstall %+v", again)
	}
}

func TestUninstallPurgeRemovesEverything(t *testing.T) {
	r := newRig(t)
	r.install("3.0.1", false, "")
	_ = os.MkdirAll(filepath.Join(r.root, ToolsDir, "go"), 0o755)
	res := r.uninstall(UninstallOptions{Purge: true})
	if res.Result != ResultUninstalled || len(res.Kept) != 0 {
		t.Fatalf("%+v", res)
	}
	for _, p := range []string{BinPath, UnitPath, ConfigDir, StateDir, ToolsDir} {
		if exists(filepath.Join(r.root, p)) {
			t.Errorf("%s left", p)
		}
	}
	// A new install is a fresh identity.
	if again := r.install("3.0.1", false, ""); again.Result != ResultInstalled {
		t.Fatalf("%+v", again)
	}
}

func TestUninstallAsksAboutSessions(t *testing.T) {
	r := newRig(t)
	r.install("3.0.1", false, "")
	r.sys.sessions = []string{"main", "build"}
	r.sys.tmuxUnits = []string{"aurora3-tmux-1"}
	snap, st := r.snapshot(), r.sysState()
	res := r.uninstall(UninstallOptions{})
	if res.Result != ResultSessions || len(res.Sessions) != 2 || !strings.Contains(res.Message, "main") || UninstallExitCode(res) != 1 {
		t.Fatalf("%+v", res)
	}
	same(t, "files", snap, r.snapshot())
	if r.sysState() != st || len(r.sys.tmuxUnits) != 1 {
		t.Fatal("changed without --force")
	}
	// The user confirmed (D-31).
	res = r.uninstall(UninstallOptions{Force: true})
	if res.Result != ResultUninstalled {
		t.Fatalf("%+v", res)
	}
	if len(r.sys.tmuxUnits) != 0 {
		t.Fatal("tmux unit left running (D-37)")
	}
	if !strings.Contains(strings.Join(r.sys.log, " "), "stop aurora3-tmux-1") {
		t.Fatalf("log %v", r.sys.log)
	}
}

func TestUninstallProbeChangesNothing(t *testing.T) {
	r := newRig(t)
	r.install("3.0.1", false, "")
	r.sys.sessions = []string{"main"}
	snap, st := r.snapshot(), r.sysState()
	res := r.uninstall(UninstallOptions{Probe: true, Force: true, Purge: true})
	if res.Result != ResultProbe || len(res.Sessions) != 1 || len(res.Present) != 4 {
		t.Fatalf("%+v", res)
	}
	same(t, "files", snap, r.snapshot())
	if r.sysState() != st {
		t.Fatal("system changed")
	}
}

func TestUninstallStopsAtAFailedStepAndReports(t *testing.T) {
	r := newRig(t)
	r.install("3.0.1", false, "")
	r.sys.tmuxUnits = []string{"aurora3-tmux-1"}
	r.sys.stopFails = map[string]bool{"aurora3-tmux-1": true}
	res := r.uninstall(UninstallOptions{Force: true})
	if res.Result != ResultPartial || res.Failed != "stop-sessions" || strings.Join(res.Done, ",") != "stop-agent" || UninstallExitCode(res) != 4 {
		t.Fatalf("%+v", res)
	}
	if !strings.Contains(res.Message, "结束终端会话") || !strings.Contains(res.Message, "停止 agent") {
		t.Fatal(res.Message)
	}
	// No rollback (D-34): the agent stays stopped, the files stay.
	if r.sys.active || !exists(filepath.Join(r.root, BinPath)) {
		t.Fatal(r.sysState())
	}
	// Retrying after the cause is gone finishes.
	r.sys.stopFails = nil
	if res := r.uninstall(UninstallOptions{Force: true}); res.Result != ResultUninstalled {
		t.Fatalf("%+v", res)
	}
}

func TestUninstallOnACleanMachine(t *testing.T) {
	r := newRig(t)
	snap := r.snapshot()
	res := r.uninstall(UninstallOptions{Purge: true})
	if res.Result != ResultUninstalled || !strings.Contains(res.Message, "没有") {
		t.Fatalf("%+v", res)
	}
	same(t, "files", snap, r.snapshot())
}

func TestUninstallLeavesV2Alone(t *testing.T) {
	r := newRig(t)
	v2 := []string{"/usr/local/bin/aurora-agent", "/etc/systemd/system/aurora-agent.service", "/etc/aurora/agent.json", "/var/lib/aurora/agent.crt"}
	for _, p := range v2 {
		_ = os.MkdirAll(filepath.Dir(filepath.Join(r.root, p)), 0o755)
		_ = os.WriteFile(filepath.Join(r.root, p), []byte("v2"), 0o644)
	}
	r.install("3.0.1", false, "")
	r.uninstall(UninstallOptions{Force: true, Purge: true})
	for _, p := range v2 {
		if b, err := os.ReadFile(filepath.Join(r.root, p)); err != nil || string(b) != "v2" {
			t.Errorf("v2 file %s touched", p)
		}
	}
}
