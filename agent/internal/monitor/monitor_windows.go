// Native Windows counters: no polling PowerShell process, administrator rights,
// or WMI service dependency. Wire units match the Linux monitor.
package monitor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"sort"
	"sync"
	"time"
	"unsafe"

	"aurora3/internal/service"
	"aurora3/internal/wire"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

type Root struct{ ID, Label, Path string }
type Auditor interface{ Write(string, map[string]any) }
type Env struct {
	Roots   []Root
	Audit   Auditor
	gpuOnce sync.Once
	gpu     *gpuCollector
	mu      sync.Mutex
	last    map[uint32]processSample
	lastAt  time.Time
}
type processSample struct{ created, ticks uint64 }
type svc struct{ e *Env }

func (e *Env) Service() service.Service        { return svc{e} }
func (svc) ID() string                         { return "monitor" }
func (svc) Dependencies() []service.Dependency { return nil }
func (s svc) Operations() []service.Operation {
	return []service.Operation{{Name: "sys.metrics", Handle: s.e.sysMetrics}, {Name: "proc.list", Handle: s.e.procList}, {Name: "gpu.info", Handle: s.e.gpuInfo}}
}

var (
	kernel        = windows.NewLazySystemDLL("kernel32.dll")
	systemTimes   = kernel.NewProc("GetSystemTimes")
	memoryStatus  = kernel.NewProc("GlobalMemoryStatusEx")
	tickCount     = kernel.NewProc("GetTickCount64")
	processMemory = kernel.NewProc("K32GetProcessMemoryInfo")
)

type memoryInfo struct {
	Length, Load                                                                                         uint32
	TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual uint64
}

func physicalMemory() (memoryInfo, error) {
	m := memoryInfo{}
	m.Length = uint32(unsafe.Sizeof(m))
	ok, _, err := memoryStatus.Call(uintptr(unsafe.Pointer(&m)))
	if ok == 0 {
		return m, err
	}
	return m, nil
}
func ticks(t windows.Filetime) uint64 { return uint64(t.HighDateTime)<<32 | uint64(t.LowDateTime) }

func (e *Env) sysMetrics(ctx context.Context, _ json.RawMessage) (any, error) {
	var idle, kern, user windows.Filetime
	ok, _, err := systemTimes.Call(uintptr(unsafe.Pointer(&idle)), uintptr(unsafe.Pointer(&kern)), uintptr(unsafe.Pointer(&user)))
	if ok == 0 {
		return nil, wire.Errf(wire.CodeUnavailable, "读取 CPU 状态失败：%v", err)
	}
	m, err := physicalMemory()
	if err != nil {
		return nil, wire.Errf(wire.CodeUnavailable, "读取内存状态失败：%v", err)
	}
	model := "Windows CPU"
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `HARDWARE\DESCRIPTION\System\CentralProcessor\0`, registry.QUERY_VALUE); err == nil {
		if name, _, err := k.GetStringValue("ProcessorNameString"); err == nil {
			model = name
		}
		k.Close()
	}
	up, _, _ := tickCount.Call()
	v := windows.RtlGetVersion()
	host, _ := os.Hostname()
	g, _ := e.gpuSampler().snapshot(ctx, false)
	return map[string]any{
		"ts": float64(time.Now().UnixMilli()) / 1000, "host": host, "os": "Windows", "platform": "windows",
		"kernel":    fmt.Sprintf("%d.%d.%d", v.MajorVersion, v.MinorVersion, v.BuildNumber),
		"cpu_model": model, "cpu_count": runtime.NumCPU(), "cpu": []uint64{ticks(user), 0, ticks(kern) - ticks(idle), ticks(idle), 0, 0, 0, 0},
		"uptime": float64(up) / 1000, "load": []float64{}, "load_supported": false,
		"memory": map[string]uint64{"MemTotal": m.TotalPhys, "MemAvailable": m.AvailPhys, "SwapTotal": 0, "SwapFree": 0,
			"CommitTotal": m.TotalPageFile - m.AvailPageFile, "CommitLimit": m.TotalPageFile},
		"disks": windowsDisks(), "gpus": g.GPUs, "gpu_error": g.Error, "gpu_status": g.Status, "gpu_ts": g.TS, "gpu_stale": g.Stale,
	}, nil
}

func windowsDisks() []map[string]any {
	out := []map[string]any{}
	mask, _ := windows.GetLogicalDrives()
	for i := 0; i < 26; i++ {
		if mask&(1<<i) == 0 {
			continue
		}
		path := fmt.Sprintf("%c:\\", 'A'+i)
		p, _ := windows.UTF16PtrFromString(path)
		if windows.GetDriveType(p) != windows.DRIVE_FIXED {
			continue
		}
		var avail, total, free uint64
		if windows.GetDiskFreeSpaceEx(p, &avail, &total, &free) != nil {
			continue
		}
		out = append(out, map[string]any{"mount": path, "fstype": "本地磁盘", "total": total, "used": total - free, "free": avail})
	}
	return out
}

type memoryCounters struct {
	Size, Faults                                                                                 uint32
	PeakWorkingSet, WorkingSet, PeakPaged, Paged, PeakNonPaged, NonPaged, Pagefile, PeakPagefile uintptr
}

func (e *Env) procList(ctx context.Context, raw json.RawMessage) (any, error) {
	var args struct {
		Limit int `json:"limit"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &args) != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "参数格式错误")
	}
	limit := args.Limit
	if limit <= 0 {
		limit = 30
	}
	limit = min(limit, 200)
	e.mu.Lock()
	defer e.mu.Unlock()
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, wire.Errf(wire.CodeUnavailable, "读取进程失败：%v", err)
	}
	defer windows.CloseHandle(snapshot)
	row := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	now := time.Now()
	seconds := now.Sub(e.lastAt).Seconds()
	next := map[uint32]processSample{}
	rows := []map[string]any{}
	m, _ := physicalMemory()
	for err := windows.Process32First(snapshot, &row); err == nil; err = windows.Process32Next(snapshot, &row) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if row.ProcessID == 0 {
			continue
		}
		name := windows.UTF16ToString(row.ExeFile[:])
		p := map[string]any{"pid": row.ProcessID, "args": name, "user": "—", "cpu": nil, "rss": nil, "memory": nil}
		h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_VM_READ, false, row.ProcessID)
		if err != nil {
			h, err = windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, row.ProcessID)
		}
		if err == nil {
			var created, exited, kt, ut windows.Filetime
			if windows.GetProcessTimes(h, &created, &exited, &kt, &ut) == nil {
				cur := processSample{ticks(created), ticks(kt) + ticks(ut)}
				if prev, ok := e.last[row.ProcessID]; ok && prev.created == cur.created && cur.ticks >= prev.ticks && seconds > 0 {
					p["cpu"] = float64(cur.ticks-prev.ticks) / 1e7 / seconds * 100
				}
				next[row.ProcessID] = cur
			}
			mem := memoryCounters{Size: uint32(unsafe.Sizeof(memoryCounters{}))}
			if ok, _, _ := processMemory.Call(uintptr(h), uintptr(unsafe.Pointer(&mem)), uintptr(mem.Size)); ok != 0 {
				p["rss"] = uint64(mem.WorkingSet)
				if m.TotalPhys > 0 {
					p["memory"] = float64(mem.WorkingSet) / float64(m.TotalPhys) * 100
				}
			}
			var token windows.Token
			if windows.OpenProcessToken(h, windows.TOKEN_QUERY, &token) == nil {
				if u, err := token.GetTokenUser(); err == nil {
					// SID lookup may contact a domain controller; keep sampling local.
					p["user"] = u.User.Sid.String()
				}
				token.Close()
			}
			windows.CloseHandle(h)
		}
		rows = append(rows, p)
	}
	e.last, e.lastAt = next, now
	cpu := func(p map[string]any) float64 {
		if v, ok := p["cpu"].(float64); ok {
			return v
		}
		return -1
	}
	sort.SliceStable(rows, func(i, j int) bool { return cpu(rows[i]) > cpu(rows[j]) })
	return map[string]any{"processes": rows[:min(limit, len(rows))], "total": len(rows)}, nil
}
