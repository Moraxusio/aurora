//go:build linux || windows

package monitor

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// gpu.info is independent of terminal sessions and never modifies GPU settings.
// Memory is MiB (including the legacy sys.metrics fields); clocks MHz, power W,
// temperature Celsius, utilization/fan percent. Unsupported values are null.
type gpuSnapshot struct {
	GPUs   []map[string]any `json:"gpus"`
	TS     float64          `json:"ts"` // last successful sample, not last request
	Status string           `json:"status"`
	Error  string           `json:"error"`
	Stale  bool             `json:"stale"`
	Driver string           `json:"driver"`
	CUDA   string           `json:"cuda"` // driver-supported version, not toolkit
}

type gpuCollector struct {
	mu      sync.Mutex
	data    gpuSnapshot // published snapshots are immutable
	next    time.Time
	flight  chan struct{}
	run     func(context.Context) ([]byte, error)
	timeout time.Duration
}

func (s *Env) gpuSampler() *gpuCollector {
	s.gpuOnce.Do(func() {
		s.gpu = &gpuCollector{run: runNvidiaSMI, timeout: 3 * time.Second,
			data: gpuSnapshot{GPUs: []map[string]any{}, Status: "loading"}}
	})
	return s.gpu
}

func (s *Env) gpuInfo(ctx context.Context, _ json.RawMessage) (any, error) {
	return s.gpuSampler().snapshot(ctx, true)
}

// Coalesce callers without holding a lock during exec. A canceled request stops
// waiting; the shared, bounded sample still serves other clients. No idle timer.
func (c *gpuCollector) snapshot(ctx context.Context, wait bool) (gpuSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return gpuSnapshot{}, err
	}
	c.mu.Lock()
	if c.flight == nil && !time.Now().Before(c.next) {
		c.flight = make(chan struct{})
		go c.collect()
	}
	done, data := c.flight, c.data
	c.mu.Unlock()
	if wait && done != nil {
		select {
		case <-ctx.Done():
			return gpuSnapshot{}, ctx.Err()
		case <-done:
		}
		c.mu.Lock()
		data = c.data
		c.mu.Unlock()
	}
	return data, nil
}

func (c *gpuCollector) collect() {
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()
	out, err := c.run(ctx)
	data := gpuSnapshot{GPUs: []map[string]any{}, Status: "error"}
	retry := 15 * time.Second
	switch {
	case ctx.Err() != nil:
		data.Error = "nvidia-smi 响应超时，稍后自动重试"
		retry = time.Minute
	case errors.Is(err, exec.ErrNotFound):
		data.Status, data.Error = "unavailable", "未找到 nvidia-smi；NVIDIA GPU 监控需要执行端安装驱动及该工具"
		retry = time.Minute
	case err != nil:
		data.Error = "nvidia-smi 执行失败，请检查执行端 NVIDIA 驱动及设备访问权限"
	default:
		data, err = parseNvidiaXML(out)
		if err != nil {
			data = gpuSnapshot{GPUs: []map[string]any{}, Status: "error", Error: "无法解析 nvidia-smi 状态数据"}
		} else {
			data.TS = float64(time.Now().UnixMilli()) / 1000
			retry = 1500 * time.Millisecond
		}
	}
	c.mu.Lock()
	if data.Error != "" && c.data.TS != 0 {
		data.GPUs, data.TS, data.Driver, data.CUDA = c.data.GPUs, c.data.TS, c.data.Driver, c.data.CUDA
		data.Stale = true
	}
	c.data, c.next = data, time.Now().Add(retry)
	close(c.flight)
	c.flight = nil
	c.mu.Unlock()
}

const maxGPUOutput = 8 << 20

// Do not embed bytes.Buffer: its promoted ReadFrom would let io.Copy bypass
// Write's size limit when exec copies the child's stdout pipe.
type gpuOutput struct{ buf bytes.Buffer }

func (b *gpuOutput) Write(p []byte) (int, error) {
	if b.buf.Len()+len(p) > maxGPUOutput {
		return 0, errors.New("GPU output too large")
	}
	return b.buf.Write(p)
}

func runNvidiaSMI(ctx context.Context) ([]byte, error) {
	cmd, err := gpuCommand(ctx)
	if err != nil {
		return nil, err
	}
	// XML avoids CSV quoting bugs and unsupported query-field failures on older
	// drivers. Unknown XML elements are ignored; optional fields remain null.
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	cmd.WaitDelay = 200 * time.Millisecond
	var out gpuOutput
	cmd.Stdout = &out
	err = cmd.Run()
	return out.buf.Bytes(), err
}

type gpuXML struct {
	XMLName xml.Name
	Text    string   `xml:",chardata"`
	Nodes   []gpuXML `xml:",any"`
}

func (n gpuXML) node(path string) gpuXML {
	for _, name := range strings.Split(path, "/") {
		found := gpuXML{}
		for _, child := range n.Nodes {
			if child.XMLName.Local == name {
				found = child
				break
			}
		}
		n = found
	}
	return n
}

func (n gpuXML) text(paths ...string) string {
	for _, path := range paths {
		v := strings.TrimSpace(n.node(path).Text)
		switch strings.ToLower(v) {
		case "", "n/a", "[n/a]", "not supported", "[not supported]", "unknown", "not available":
			continue
		}
		return v
	}
	return ""
}

func (n gpuXML) number(paths ...string) any {
	v := strings.Fields(n.text(paths...))
	if len(v) == 0 {
		return nil
	}
	f, err := strconv.ParseFloat(strings.TrimSuffix(v[0], "x"), 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) || f < 0 {
		return nil
	}
	// nvidia-smi normally reports MiB. Normalize alternate memory units too.
	if len(v) > 1 {
		switch v[1] {
		case "GiB":
			f *= 1024
		case "KiB":
			f /= 1024
		case "B":
			f /= 1 << 20
		}
	}
	if math.IsInf(f, 0) {
		return nil
	}
	return f
}

func parseNvidiaXML(raw []byte) (gpuSnapshot, error) {
	var root gpuXML
	if len(raw) > maxGPUOutput {
		return gpuSnapshot{}, errors.New("GPU output too large")
	}
	if err := xml.Unmarshal(raw, &root); err != nil {
		return gpuSnapshot{}, err
	}
	if root.XMLName.Local != "nvidia_smi_log" {
		return gpuSnapshot{}, errors.New("unexpected GPU document")
	}
	data := gpuSnapshot{GPUs: []map[string]any{}, Status: "empty", Driver: root.text("driver_version"), CUDA: root.text("cuda_version")}
	for _, g := range root.Nodes {
		if g.XMLName.Local != "gpu" {
			continue
		}
		row := map[string]any{
			"index": len(data.GPUs), "name": g.text("product_name"), "uuid": g.text("uuid"),
			"architecture": g.text("product_architecture"), "bus_id": g.text("pci/pci_bus_id"),
			"util": g.number("utilization/gpu_util"), "mem_util": g.number("utilization/memory_util"),
			"encoder_util": g.number("utilization/encoder_util"), "decoder_util": g.number("utilization/decoder_util"),
			"mem_used": g.number("fb_memory_usage/used"), "mem_total": g.number("fb_memory_usage/total"),
			"mem_free": g.number("fb_memory_usage/free"), "mem_reserved": g.number("fb_memory_usage/reserved"),
			"temp": g.number("temperature/gpu_temp"), "mem_temp": g.number("temperature/memory_temp"),
			"temp_limit": g.number("temperature/gpu_temp_slow_threshold"), "fan": g.number("fan_speed"),
			"power":       g.number("gpu_power_readings/instant_power_draw", "gpu_power_readings/power_draw", "power_readings/power_draw", "gpu_power_readings/average_power_draw"),
			"power_limit": g.number("gpu_power_readings/enforced_power_limit", "gpu_power_readings/current_power_limit", "gpu_power_readings/power_limit", "power_readings/enforced_power_limit", "power_readings/power_limit"),
			"pstate":      g.text("performance_state"), "compute_mode": g.text("compute_mode"),
			"persistence": g.text("persistence_mode"), "mig_mode": g.text("mig_mode/current_mig"),
			"clock_graphics": g.number("clocks/graphics_clock"), "clock_sm": g.number("clocks/sm_clock"),
			"clock_memory": g.number("clocks/mem_clock"), "clock_video": g.number("clocks/video_clock"),
			"clock_graphics_max": g.number("max_clocks/graphics_clock"), "clock_memory_max": g.number("max_clocks/mem_clock"),
			"pcie_gen":        g.number("pci/pci_gpu_link_info/pcie_gen/current_link_gen"),
			"pcie_gen_max":    g.number("pci/pci_gpu_link_info/pcie_gen/max_link_gen"),
			"pcie_width":      g.number("pci/pci_gpu_link_info/link_widths/current_link_width"),
			"pcie_width_max":  g.number("pci/pci_gpu_link_info/link_widths/max_link_width"),
			"ecc_corrected":   g.number("ecc_errors/volatile/single_bit/total", "ecc_errors/volatile/corrected/total"),
			"ecc_uncorrected": g.number("ecc_errors/volatile/double_bit/total", "ecc_errors/volatile/uncorrected/total"),
		}
		reasons := g.node("clocks_event_reasons")
		if reasons.XMLName.Local == "" {
			reasons = g.node("clocks_throttle_reasons")
		}
		active := []string{}
		reasonsAvailable := false
		for _, r := range reasons.Nodes {
			state := strings.TrimSpace(r.Text)
			if strings.EqualFold(state, "Active") || strings.EqualFold(state, "Not Active") {
				reasonsAvailable = true
			}
			if strings.EqualFold(state, "Active") {
				name := strings.TrimPrefix(strings.TrimPrefix(r.XMLName.Local, "clocks_throttle_reason_"), "clocks_event_reason_")
				active = append(active, name)
			}
		}
		row["clock_reasons"], row["clock_reasons_available"] = active, reasonsAvailable
		procs := []map[string]any{}
		pn := g.node("processes")
		for _, p := range pn.Nodes {
			if p.XMLName.Local != "process_info" {
				continue
			}
			pid, err := strconv.Atoi(p.text("pid"))
			if err != nil || pid <= 0 {
				continue
			}
			procs = append(procs, map[string]any{"pid": pid, "name": p.text("process_name"), "type": p.text("type"),
				"mem_used": p.number("used_memory"), "gpu_instance_id": p.number("gpu_instance_id"), "compute_instance_id": p.number("compute_instance_id")})
		}
		row["processes"], row["processes_available"] = procs, pn.XMLName.Local != "" && strings.TrimSpace(pn.Text) == ""
		data.GPUs = append(data.GPUs, row)
	}
	if len(data.GPUs) > 0 {
		data.Status = "ok"
	} else if root.text("attached_gpus") != "0" {
		return gpuSnapshot{}, errors.New("missing GPU records")
	}
	return data, nil
}
