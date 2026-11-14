//go:build linux

package monitor

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"aurora3/internal/service"
)

func gpuFixture(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/nvidia.xml")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestGPUDetailsAcrossDriverLayouts(t *testing.T) {
	d, err := parseNvidiaXML(gpuFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	if d.Status != "ok" || len(d.GPUs) != 2 || d.Driver != "580.95.05" || d.CUDA != "13.0" {
		t.Fatalf("snapshot: %+v", d)
	}
	a, b := d.GPUs[0], d.GPUs[1]
	for key, want := range map[string]any{"index": 0, "util": float64(82), "mem_used": float64(24576), "power": 238.52, "power_limit": float64(300), "pcie_width": float64(16), "ecc_corrected": float64(2), "ecc_uncorrected": float64(0), "mem_temp": nil, "clock_sm": float64(1695)} {
		if a[key] != want {
			t.Errorf("first GPU %s = %v, want %v", key, a[key], want)
		}
	}
	for key, want := range map[string]any{"index": 1, "util": nil, "fan": nil, "encoder_util": nil, "mem_total": float64(81920), "power": 95.25, "power_limit": float64(350), "mig_mode": "Enabled"} {
		if b[key] != want {
			t.Errorf("second GPU %s = %v, want %v", key, b[key], want)
		}
	}
	if strings.Join(a["clock_reasons"].([]string), ",") != "sw_power_cap" || strings.Join(b["clock_reasons"].([]string), ",") != "gpu_idle" {
		t.Fatal("clock reasons lost")
	}
	p := a["processes"].([]map[string]any)
	if len(p) != 2 || p[0]["pid"] != 4123 || p[0]["name"] != "/opt/train, eval/python & worker" || p[0]["gpu_instance_id"] != nil {
		t.Fatalf("processes: %+v", p)
	}
	p = b["processes"].([]map[string]any)
	if p[0]["mem_used"] != nil || p[0]["gpu_instance_id"] != float64(1) || p[0]["compute_instance_id"] != float64(0) {
		t.Fatalf("MIG process: %+v", p)
	}
	if _, err := json.Marshal(d); err != nil {
		t.Fatal(err)
	}
}

func TestGPUUnknownIsNotZeroAndEmptyIsNotFailure(t *testing.T) {
	for _, raw := range []string{"<bad/>", "not XML", "<nvidia_smi_log/>", "<nvidia_smi_log><attached_gpus>2</attached_gpus></nvidia_smi_log>"} {
		if _, err := parseNvidiaXML([]byte(raw)); err == nil {
			t.Errorf("accepted %q", raw)
		}
	}
	d, err := parseNvidiaXML([]byte("<nvidia_smi_log><attached_gpus>0</attached_gpus></nvidia_smi_log>"))
	if err != nil || d.Status != "empty" || d.GPUs == nil {
		t.Fatalf("empty: %+v, %v", d, err)
	}
	for _, value := range []string{"N/A", "[Not Supported]", "NaN", "+Inf", "-1", "bad", "1e308 GiB"} {
		d, err := parseNvidiaXML([]byte("<nvidia_smi_log><gpu><utilization><gpu_util>" + value + "</gpu_util></utilization><processes>N/A</processes></gpu></nvidia_smi_log>"))
		if err != nil || d.GPUs[0]["util"] != nil || d.GPUs[0]["processes_available"] != false || d.GPUs[0]["clock_reasons_available"] != false {
			t.Fatalf("unknown %q: %+v %v", value, d, err)
		}
	}
}

func TestGPUCoalescingCancellationAndSystemIsolation(t *testing.T) {
	raw := gpuFixture(t)
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	e := &Env{}
	c := e.gpuSampler()
	c.run = func(ctx context.Context) ([]byte, error) {
		calls.Add(1)
		close(started)
		select {
		case <-release:
			return raw, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	d, err := c.snapshot(context.Background(), false)
	if err != nil || d.Status != "loading" {
		t.Fatalf("initial: %+v %v", d, err)
	}
	<-started
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.snapshot(ctx, true); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() { _, err := e.sysMetrics(context.Background(), nil); finished <- err }()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("system metrics blocked on GPU")
	}
	var wg sync.WaitGroup
	for range 12 {
		wg.Go(func() {
			d, err := c.snapshot(context.Background(), true)
			if err != nil || d.Status != "ok" || len(d.GPUs) != 2 {
				t.Errorf("shared sample: %+v %v", d, err)
			}
		})
	}
	close(release)
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatalf("ran %d samplers", calls.Load())
	}
}

func TestGPUFailureKeepsTimestampAndBacksOffThenRecovers(t *testing.T) {
	raw := gpuFixture(t)
	var fail bool
	var calls int
	c := &gpuCollector{timeout: time.Second, run: func(context.Context) ([]byte, error) {
		calls++
		if fail {
			return nil, errors.New("driver failed")
		}
		return raw, nil
	}}
	first, _ := c.snapshot(context.Background(), true)
	fail = true
	c.mu.Lock()
	c.next = time.Time{}
	c.mu.Unlock()
	d, _ := c.snapshot(context.Background(), true)
	if !d.Stale || d.TS != first.TS || len(d.GPUs) != 2 || d.Error == "" || d.Status != "error" {
		t.Fatalf("stale: %+v", d)
	}
	for range 10 {
		_, _ = c.snapshot(context.Background(), true)
	}
	if calls != 2 {
		t.Fatalf("failure not backed off: %d", calls)
	}
	fail = false
	c.mu.Lock()
	c.next = time.Time{}
	c.mu.Unlock()
	d, _ = c.snapshot(context.Background(), true)
	if d.Stale || d.Error != "" || d.Status != "ok" {
		t.Fatalf("recovery: %+v", d)
	}
}

func TestGPUMissingAndTimeoutAreExplicit(t *testing.T) {
	for _, tc := range []struct {
		name, status, message string
		run                   func(context.Context) ([]byte, error)
	}{
		{"missing", "unavailable", "未找到", func(context.Context) ([]byte, error) { return nil, exec.ErrNotFound }},
		{"timeout", "error", "超时", func(ctx context.Context) ([]byte, error) { <-ctx.Done(); return nil, ctx.Err() }},
		{"invalid", "error", "解析", func(context.Context) ([]byte, error) { return []byte("<broken>"), nil }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := &gpuCollector{run: tc.run, timeout: 10 * time.Millisecond}
			d, err := c.snapshot(context.Background(), true)
			if err != nil || d.Status != tc.status || !strings.Contains(d.Error, tc.message) || d.Stale || d.TS != 0 {
				t.Fatalf("snapshot: %+v %v", d, err)
			}
		})
	}
}

func TestNvidiaCommandAndBoundedOutput(t *testing.T) {
	dir := t.TempDir()
	raw := gpuFixture(t)
	file := filepath.Join(dir, "nvidia-smi")
	script := "#!/bin/sh\n[ \"$1 $2\" = '-q -x' ] || exit 4\n[ \"$LC_ALL\" = C ] || exit 5\ncat <<'GPU_XML'\n" + string(raw) + "\nGPU_XML\n"
	if err := os.WriteFile(file, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	out, err := runNvidiaSMI(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parseNvidiaXML(out); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("#!/bin/sh\nexec /bin/sleep 10\n"), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, err := runNvidiaSMI(ctx); err == nil || ctx.Err() == nil {
		t.Fatal("command did not time out")
	}
	t.Setenv("PATH", t.TempDir())
	if _, err := runNvidiaSMI(context.Background()); !errors.Is(err, exec.ErrNotFound) {
		t.Fatalf("missing tool: %v", err)
	}
	var output gpuOutput
	// LimitReader has no WriterTo, matching the generic pipe-copy path. This
	// catches a promoted bytes.Buffer.ReadFrom silently bypassing the bound.
	if _, err := io.Copy(&output, io.LimitReader(strings.NewReader(strings.Repeat("x", maxGPUOutput+1)), maxGPUOutput+1)); err == nil || output.buf.Len() > maxGPUOutput {
		t.Fatal("unbounded output")
	}
}

func TestGPUOperationIsOptional(t *testing.T) {
	e := &Env{}
	e.gpuSampler().run = func(context.Context) ([]byte, error) { return nil, exec.ErrNotFound }
	r, err := service.NewRegistry([]service.Service{e.Service()}, nil, func(string) error { return exec.ErrNotFound })
	if err != nil {
		t.Fatal(err)
	}
	result, err := r.Dispatch(context.Background(), "gpu.info", nil)
	if err != nil || result.(gpuSnapshot).Status != "unavailable" {
		t.Fatalf("optional GPU dispatch: %+v, %v", result, err)
	}
	if _, err := r.Dispatch(context.Background(), "sys.metrics", nil); err != nil {
		t.Fatal("GPU tool disabled system metrics:", err)
	}
	if err := r.SetEnabled("monitor", false); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Dispatch(context.Background(), "gpu.info", nil); !errors.Is(err, service.ErrDisabled) {
		t.Fatalf("disabled monitor still dispatched: %v", err)
	}
}
