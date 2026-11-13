// Package winlocal implements current-user execution, not a Windows SCM service.
package winlocal

import (
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"strings"
	"unsafe"
)

func Shell() string {
	if p, err := exec.LookPath("pwsh.exe"); err == nil {
		return p
	}
	return os.Getenv("SystemRoot") + `\System32\WindowsPowerShell\v1.0\powershell.exe`
}

// A non-inherited job handle kills this agent and all nested child jobs if the
// client pipe closes or the agent crashes. No unrelated process is enumerated.
func NewJob() (windows.Handle, error) {
	h, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(h, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)))
	if err != nil {
		windows.CloseHandle(h)
		return 0, err
	}
	return h, nil
}
func BindSelf() (windows.Handle, error) {
	h, err := NewJob()
	if err != nil {
		return 0, err
	}
	if err = windows.AssignProcessToJobObject(h, windows.CurrentProcess()); err != nil {
		windows.CloseHandle(h)
		return 0, fmt.Errorf("绑定本地任务生命周期失败: %w", err)
	}
	return h, nil
}

// Merge is case-insensitive on Windows and avoids duplicate proxy variable keys.
func Merge(base []string, extra map[string]string) []string {
	out := []string{}
	for _, v := range base {
		k, _, _ := strings.Cut(v, "=")
		replace := false
		for x := range extra {
			if strings.EqualFold(k, x) {
				replace = true
				break
			}
		}
		if !replace {
			out = append(out, v)
		}
	}
	for k, v := range extra {
		out = append(out, k+"="+v)
	}
	return out
}

// Environment proxy takes priority; otherwise use the current user's manual
// WinINET HTTP(S) proxy. PAC is deliberately not evaluated here.
func ProxyEnv() map[string]string {
	out := map[string]string{}
	for _, k := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"} {
		if v := os.Getenv(k); v != "" {
			out[k] = v
		}
	}
	if out["HTTP_PROXY"] != "" || out["HTTPS_PROXY"] != "" || out["ALL_PROXY"] != "" {
		return out
	}
	return systemProxy(out)
}
