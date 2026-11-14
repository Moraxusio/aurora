//go:build linux || windows

package monitor

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"
)

// Opt-in hardware -> production parser -> GUI fixture. Device identifiers and
// process names are replaced before writing; no profile or agent login is used.
func TestNativeGPUFixture(t *testing.T) {
	out := os.Getenv("AURORA_GPU_NATIVE_FIXTURE")
	if out == "" {
		t.Skip("set AURORA_GPU_NATIVE_FIXTURE to sample the local NVIDIA driver")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	raw, err := runNvidiaSMI(ctx)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := parseNvidiaXML(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.GPUs) == 0 {
		t.Fatal("no NVIDIA devices")
	}
	snapshot.TS = float64(time.Now().Unix())
	for _, gpu := range snapshot.GPUs {
		gpu["uuid"] = "GPU-native-fixture"
		gpu["bus_id"] = "00000000:01:00.0"
		if processes, ok := gpu["processes"].([]map[string]any); ok {
			for _, process := range processes {
				process["name"] = "synthetic-gpu-process.exe"
				process["pid"] = 4123
			}
		}
	}
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Logf("%d devices, driver %s, parsed hardware fixture written", len(snapshot.GPUs), snapshot.Driver)
}
