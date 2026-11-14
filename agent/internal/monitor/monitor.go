//go:build linux

package monitor

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

var (
	localFS     = map[string]bool{"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "f2fs": true, "vfat": true, "zfs": true, "jfs": true}
	skipMounts  = []string{"/var/lib/kubelet", "/var/lib/docker", "/var/lib/containerd", "/snap", "/var/snap", "/run", "/proc", "/sys"}
	physDisk    = regexp.MustCompile(`^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+)$`)
	clockTicks  = 100.0
	pageSize    = int64(os.Getpagesize())
	statesMu    sync.Mutex
	statesCache struct {
		at   time.Time
		data map[string]int
	}
)

func readFile(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

func atoi64(s string) int64 { n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64); return n }

func readOnly(opts string) bool {
	for _, o := range strings.Split(opts, ",") {
		if o == "ro" {
			return true
		}
	}
	return false
}

// LocalMounts lists local block-device filesystems. Network mounts (NFS, CIFS,
// FUSE) are never touched: statfs on a dead NFS server blocks forever.
func LocalMounts() []map[string]any {
	return localMounts(readFile("/proc/mounts"))
}

func localMounts(mountTable string) []map[string]any {
	out := []map[string]any{}
	seen := map[string]bool{}
	for _, line := range strings.Split(mountTable, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || !localFS[f[2]] || !strings.HasPrefix(f[0], "/dev/") || seen[f[0]] {
			continue
		}
		mnt := strings.ReplaceAll(f[1], "\\040", " ")
		skip := false
		for _, p := range skipMounts {
			if mnt != "/" && (mnt == p || strings.HasPrefix(mnt, p+"/")) {
				skip = true
			}
		}
		if skip {
			continue
		}
		seen[f[0]] = true
		st, ok := paths.StatfsBounded(mnt)
		if !ok {
			continue
		}
		bs := uint64(st.Bsize)
		d := map[string]any{"mount": mnt, "source": f[0], "fstype": f[2], "total": st.Blocks * bs, "used": (st.Blocks - st.Bfree) * bs, "free": st.Bavail * bs}
		// A read-only image (WSL's kernel headers, a snap) is full by design.
		if len(f) > 3 && readOnly(f[3]) {
			d["ro"] = true
		}
		out = append(out, d)
		if len(out) >= 16 {
			break
		}
	}
	return out
}

func processStates() map[string]int {
	statesMu.Lock()
	defer statesMu.Unlock()
	if time.Since(statesCache.at) < 4*time.Second && statesCache.data != nil {
		return statesCache.data
	}
	c := map[string]int{"R": 0, "S": 0, "D": 0, "Z": 0, "T": 0, "I": 0}
	entries, _ := os.ReadDir("/proc")
	total := 0
	for _, e := range entries {
		if e.Name()[0] < '0' || e.Name()[0] > '9' {
			continue
		}
		st := readFile("/proc/" + e.Name() + "/stat")
		i := strings.LastIndexByte(st, ')')
		if i < 0 || i+2 >= len(st) {
			continue
		}
		k := string(st[i+2])
		if k == "t" {
			k = "T"
		}
		if _, ok := c[k]; !ok {
			k = "S"
		}
		c[k]++
		total++
	}
	c["total"] = total
	statesCache.at, statesCache.data = time.Now(), c
	return c
}

// sysMetrics returns raw counters; the client derives rates from deltas.
func (s *Env) sysMetrics(ctx context.Context, _ json.RawMessage) (any, error) {
	var cpu []int64
	cores := [][]int64{}
	for _, line := range strings.Split(readFile("/proc/stat"), "\n") {
		if !strings.HasPrefix(line, "cpu") {
			continue
		}
		f := strings.Fields(line)
		vals := make([]int64, 0, 8)
		for _, x := range f[1:min(len(f), 9)] {
			vals = append(vals, atoi64(x))
		}
		if f[0] == "cpu" {
			cpu = vals
		} else {
			cores = append(cores, vals)
		}
	}
	mem := map[string]int64{}
	for _, line := range strings.Split(readFile("/proc/meminfo"), "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch k {
		case "MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached", "SReclaimable", "Shmem", "SwapTotal", "SwapFree":
			mem[k] = atoi64(strings.Fields(v)[0]) * 1024
		}
	}
	net := []map[string]any{}
	for i, line := range strings.Split(readFile("/proc/net/dev"), "\n") {
		name, data, ok := strings.Cut(line, ":")
		if i < 2 || !ok {
			continue
		}
		name = strings.TrimSpace(name)
		if _, err := os.Stat("/sys/class/net/" + name + "/device"); err != nil {
			continue // physical NICs only
		}
		f := strings.Fields(data)
		if len(f) >= 9 {
			net = append(net, map[string]any{"name": name, "rx": atoi64(f[0]), "tx": atoi64(f[8])})
		}
	}
	diskio := []map[string]any{}
	for _, line := range strings.Split(readFile("/proc/diskstats"), "\n") {
		f := strings.Fields(line)
		if len(f) >= 10 && physDisk.MatchString(f[2]) {
			diskio = append(diskio, map[string]any{"name": f[2], "read": atoi64(f[5]) * 512, "write": atoi64(f[9]) * 512})
		}
	}
	load := []float64{0, 0, 0}
	threads := map[string]int64{}
	if la := strings.Fields(readFile("/proc/loadavg")); len(la) >= 4 {
		for i := 0; i < 3; i++ {
			load[i], _ = strconv.ParseFloat(la[i], 64)
		}
		r, t, _ := strings.Cut(la[3], "/")
		threads["running"], threads["total"] = atoi64(r), atoi64(t)
	}
	var uptime float64
	if f := strings.Fields(readFile("/proc/uptime")); len(f) > 0 {
		uptime, _ = strconv.ParseFloat(f[0], 64)
	}
	model := ""
	for _, line := range strings.Split(readFile("/proc/cpuinfo"), "\n") {
		if strings.HasPrefix(line, "model name") {
			_, model, _ = strings.Cut(line, ":")
			model = strings.TrimSpace(model)
			break
		}
	}
	host, _ := os.Hostname()
	var uts syscall.Utsname
	_ = syscall.Uname(&uts)
	// Old clients still receive GPU fields, but CPU/memory never wait for a driver.
	g, _ := s.gpuSampler().snapshot(ctx, false)
	return map[string]any{"ts": float64(time.Now().UnixNano()) / 1e9, "host": host, "kernel": utsString(uts.Release[:]), "os": osName(),
		"cpu_model": model, "cpu_count": max(1, len(cores)), "cpu": cpu, "cores": cores, "load": load, "threads": threads,
		"states": processStates(), "uptime": uptime, "memory": mem, "disks": LocalMounts(), "diskio": diskio, "net": net,
		"gpus": g.GPUs, "gpu_error": g.Error, "gpu_status": g.Status, "gpu_ts": g.TS, "gpu_stale": g.Stale}, nil
}

func utsString(a []int8) string {
	b := make([]byte, 0, len(a))
	for _, c := range a {
		if c == 0 {
			break
		}
		b = append(b, byte(c))
	}
	return string(b)
}

// procSampler computes instantaneous per-process CPU from /proc tick deltas.
type procSampler struct {
	mu     sync.Mutex
	busy   bool
	last   map[int]int64
	lastAt time.Time
	users  map[string]string
}

func newProcSampler() *procSampler { return &procSampler{users: map[string]string{}} }

type procRow struct {
	PID    int     `json:"pid"`
	User   string  `json:"user"`
	State  string  `json:"state"`
	CPU    float64 `json:"cpu"`
	Memory float64 `json:"memory"`
	RSS    int64   `json:"rss"`
	Time   string  `json:"time"`
	Args   string  `json:"args"`
	ticks  int64
}

func (p *procSampler) scan() (map[int]*procRow, int) {
	entries, _ := os.ReadDir("/proc")
	rows := make(map[int]*procRow, len(entries))
	running := 0
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		st := readFile("/proc/" + e.Name() + "/stat")
		i := strings.LastIndexByte(st, ')')
		if i < 0 {
			continue
		}
		f := strings.Fields(st[i+1:])
		if len(f) < 22 {
			continue
		}
		r := &procRow{PID: pid, State: f[0], ticks: atoi64(f[11]) + atoi64(f[12]), RSS: atoi64(f[21]) * pageSize}
		if f[0] == "R" {
			running++
		}
		if j := strings.IndexByte(st, '('); j >= 0 {
			r.Args = st[j+1 : i]
		}
		rows[pid] = r
	}
	return rows, running
}

func (p *procSampler) username(pid int) string {
	uid := ""
	if f, err := os.Open("/proc/" + strconv.Itoa(pid) + "/status"); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if v, ok := strings.CutPrefix(sc.Text(), "Uid:"); ok {
				if fs := strings.Fields(v); len(fs) > 0 {
					uid = fs[0]
				}
				break
			}
		}
		f.Close()
	}
	if name, ok := p.users[uid]; ok {
		return name
	}
	name := uid
	if u, err := user.LookupId(uid); err == nil {
		name = u.Username
	}
	p.users[uid] = name
	return name
}

func cpuTime(ticks int64) string {
	sec := float64(ticks) / clockTicks
	m := int(sec) / 60
	return strconv.Itoa(m) + ":" + strconv.FormatFloat(sec-float64(m*60), 'f', 2, 64)
}

func (s *Env) procList(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Limit int `json:"limit"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	limit := a.Limit
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	p := s.sampler
	p.mu.Lock()
	if p.busy {
		p.mu.Unlock()
		return nil, wire.Errf(wire.CodeConflict, "上一次进程采样尚未完成")
	}
	p.busy = true
	p.mu.Unlock()
	defer func() { p.mu.Lock(); p.busy = false; p.mu.Unlock() }()

	prev, prevAt := p.last, p.lastAt
	if prev == nil || time.Since(prevAt) > 15*time.Second {
		first, _ := p.scan()
		prev = map[int]int64{}
		for pid, r := range first {
			prev[pid] = r.ticks
		}
		prevAt = time.Now()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(600 * time.Millisecond):
		}
	}
	rows, running := p.scan()
	now := time.Now()
	dt := now.Sub(prevAt).Seconds()
	memTotal := int64(0)
	for _, line := range strings.Split(readFile("/proc/meminfo"), "\n") {
		if v, ok := strings.CutPrefix(line, "MemTotal:"); ok {
			memTotal = atoi64(strings.Fields(v)[0]) * 1024
		}
	}
	list := make([]*procRow, 0, len(rows))
	next := make(map[int]int64, len(rows))
	for pid, r := range rows {
		next[pid] = r.ticks
		if old, ok := prev[pid]; ok && dt > 0 {
			r.CPU = float64(r.ticks-old) / clockTicks / dt * 100
		}
		if memTotal > 0 {
			r.Memory = float64(r.RSS) / float64(memTotal) * 100
		}
		list = append(list, r)
	}
	p.mu.Lock()
	p.last, p.lastAt = next, now
	p.mu.Unlock()
	sort.Slice(list, func(i, j int) bool {
		if list[i].CPU != list[j].CPU {
			return list[i].CPU > list[j].CPU
		}
		return list[i].RSS > list[j].RSS
	})
	if len(list) > limit {
		list = list[:limit]
	}
	for _, r := range list {
		r.User = p.username(r.PID)
		r.Time = cpuTime(r.ticks)
		if c := readFile("/proc/" + strconv.Itoa(r.PID) + "/cmdline"); c != "" {
			c = strings.TrimRight(strings.ReplaceAll(c, "\x00", " "), " ")
			if len(c) > 400 {
				c = c[:400]
			}
			r.Args = c
		} else {
			r.Args = "[" + r.Args + "]"
		}
	}
	return map[string]any{"processes": list, "tasks": map[string]int{"total": len(rows), "running": running}, "source": "proc"}, nil
}

func (s *Env) logTail(ctx context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Name  string `json:"name"`
		Lines int    `json:"lines"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Name != "" {
		if err := paths.CheckUnit(a.Name); err != nil {
			return nil, err
		}
	}
	lines := a.Lines
	if lines <= 0 || lines > 1000 {
		lines = 200
	}
	args := []string{"--no-pager", "-n", strconv.Itoa(lines), "--output=short-iso"}
	if a.Name != "" {
		args = append(args, "-u", a.Name)
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(cctx, "journalctl", args...).Output()
	text := string(out)
	if len(text) > 400*1024 {
		text = text[len(text)-400*1024:]
	}
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	}
	return map[string]any{"unit": a.Name, "lines": text, "exit_code": code}, nil
}

var _ = filepath.Join
