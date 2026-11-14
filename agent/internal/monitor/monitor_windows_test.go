package monitor

import (
	"context"
	"encoding/json"
	"os/exec"
	"testing"
)

func TestWindowsMetricsAndProcessCounters(t *testing.T) {
	e := &Env{}
	e.gpuSampler().run = func(context.Context) ([]byte, error) { return nil, exec.ErrNotFound }
	result, err := e.sysMetrics(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	m := result.(map[string]any)
	if m["platform"] != "windows" || len(m["cpu"].([]uint64)) != 8 || m["cpu_count"].(int) < 1 {
		t.Fatal("missing native CPU counters")
	}
	mem := m["memory"].(map[string]uint64)
	if mem["MemTotal"] == 0 || mem["MemAvailable"] > mem["MemTotal"] || mem["CommitTotal"] > mem["CommitLimit"] {
		t.Fatal("invalid memory counters")
	}
	if m["load_supported"] != false {
		t.Fatal("Windows must not invent Unix load")
	}
	for range 2 {
		result, err = e.procList(context.Background(), json.RawMessage(`{"limit":5}`))
		if err != nil {
			t.Fatal(err)
		}
		rows := result.(map[string]any)["processes"].([]map[string]any)
		if len(rows) == 0 || len(rows) > 5 {
			t.Fatal("process limit not respected")
		}
		if _, err := json.Marshal(result); err != nil {
			t.Fatal(err)
		}
	}
	g, err := e.gpuInfo(context.Background(), nil)
	if err != nil || g.(gpuSnapshot).Status != "unavailable" {
		t.Fatal("GPU absence disabled native monitor")
	}
}
