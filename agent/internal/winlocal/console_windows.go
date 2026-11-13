package winlocal

import (
	"golang.org/x/sys/windows"
	"os"
	"strings"
	"sync"
	"unsafe"
)

type Console struct {
	Input, Output        *os.File
	Handle, Process, Job windows.Handle
	once                 sync.Once
}

func StartConsole(cwd string, env []string, cols, rows int, extra ...string) (*Console, error) {
	var ir, iw, or, ow windows.Handle
	if err := windows.CreatePipe(&ir, &iw, nil, 0); err != nil {
		return nil, err
	}
	if err := windows.CreatePipe(&or, &ow, nil, 0); err != nil {
		windows.CloseHandle(ir)
		windows.CloseHandle(iw)
		return nil, err
	}
	defer windows.CloseHandle(ir)
	defer windows.CloseHandle(ow)
	c := &Console{Input: os.NewFile(uintptr(iw), "conpty-in"), Output: os.NewFile(uintptr(or), "conpty-out")}
	ok := false
	defer func() {
		if !ok {
			c.Close()
		}
	}()
	if err := windows.CreatePseudoConsole(windows.Coord{X: int16(cols), Y: int16(rows)}, ir, ow, 0, &c.Handle); err != nil {
		return nil, err
	}
	job, err := NewJob()
	if err != nil {
		return nil, err
	}
	c.Job = job
	attrs, err := windows.NewProcThreadAttributeList(2)
	if err != nil {
		return nil, err
	}
	defer attrs.Delete()
	// This attribute takes the opaque HPCON value, not a pointer to it. Pass
	// the handle as uintptr through Win32 instead of fabricating a Go pointer
	// (which would also be retained by x/sys's pointer-owning Update wrapper).
	update := windows.NewLazySystemDLL("kernel32.dll").NewProc("UpdateProcThreadAttribute")
	result, _, callErr := update.Call(uintptr(unsafe.Pointer(attrs.List())), 0, windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, uintptr(c.Handle), unsafe.Sizeof(c.Handle), 0, 0)
	if result == 0 {
		return nil, callErr
	}
	// Assign the process to its job at creation, before it can spawn children.
	if err = attrs.Update(0x0002000d, unsafe.Pointer(&job), unsafe.Sizeof(job)); err != nil {
		return nil, err
	}
	si := windows.StartupInfoEx{}
	si.Cb = uint32(unsafe.Sizeof(si))
	si.ProcThreadAttributeList = attrs.List()
	// Prevent Windows from duplicating the parent's redirected bootstrap pipes
	// into PowerShell, which would bypass the pseudoconsole entirely.
	si.Flags = windows.STARTF_USESTDHANDLES
	args := []string{windows.EscapeArg(Shell()), "-NoLogo"}
	for _, arg := range extra {
		args = append(args, windows.EscapeArg(arg))
	}
	line, err := windows.UTF16FromString(strings.Join(args, " "))
	if err != nil {
		return nil, err
	}
	dir, err := windows.UTF16PtrFromString(cwd)
	if err != nil {
		return nil, err
	}
	// Environment blocks are double-NUL terminated, not a single UTF-16 string.
	block, err := environmentBlock(env)
	if err != nil {
		return nil, err
	}
	var pi windows.ProcessInformation
	if err = windows.CreateProcess(nil, &line[0], nil, nil, false, windows.EXTENDED_STARTUPINFO_PRESENT|windows.CREATE_UNICODE_ENVIRONMENT, &block[0], dir, &si.StartupInfo, &pi); err != nil {
		return nil, err
	}
	windows.CloseHandle(pi.Thread)
	c.Process = pi.Process
	ok = true
	go func() { _, _ = windows.WaitForSingleObject(pi.Process, windows.INFINITE); c.Close() }()
	return c, nil
}
func (c *Console) Resize(cols, rows int) error {
	return windows.ResizePseudoConsole(c.Handle, windows.Coord{X: int16(cols), Y: int16(rows)})
}
func (c *Console) Close() {
	c.once.Do(func() {
		if c.Job != 0 {
			windows.CloseHandle(c.Job)
		}
		if c.Handle != 0 {
			windows.ClosePseudoConsole(c.Handle)
		}
		if c.Input != nil {
			c.Input.Close()
		}
		if c.Output != nil {
			c.Output.Close()
		}
		if c.Process != 0 {
			windows.CloseHandle(c.Process)
		}
	})
}
