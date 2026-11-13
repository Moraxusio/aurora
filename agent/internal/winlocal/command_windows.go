package winlocal

import (
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"unsafe"
)

type Command struct {
	process, job windows.Handle
	read         *os.File
	copied       chan struct{}
	killOnce     sync.Once
	closeOnce    sync.Once
}
type ExitError struct{ code int }

func (e *ExitError) Error() string { return fmt.Sprintf("exit status %d", e.code) }
func (e *ExitError) ExitCode() int { return e.code }

func environmentBlock(env []string) ([]uint16, error) {
	values := map[string]string{}
	for _, v := range env {
		k, _, ok := strings.Cut(v, "=")
		if ok {
			values[strings.ToUpper(k)] = v
		}
	}
	env = env[:0]
	for _, v := range values {
		env = append(env, v)
	}
	sort.Slice(env, func(i, j int) bool { return strings.ToUpper(env[i]) < strings.ToUpper(env[j]) })
	block := []uint16{}
	for _, v := range env {
		u, err := windows.UTF16FromString(v)
		if err != nil {
			return nil, err
		}
		block = append(block, u...)
	}
	block = append(block, 0)
	if len(block) == 1 {
		block = append(block, 0)
	}
	return block, nil
}

// Both the explicit handle list and job list are applied during CreateProcess:
// children cannot escape a cancellation race between Start and job assignment.
func StartCommand(args []string, cwd string, env []string, out io.Writer) (*Command, error) {
	sa := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), InheritHandle: 1}
	var rd, wr windows.Handle
	if err := windows.CreatePipe(&rd, &wr, &sa, 0); err != nil {
		return nil, err
	}
	defer windows.CloseHandle(wr)
	read := os.NewFile(uintptr(rd), "shell-output")
	nul, _ := windows.UTF16PtrFromString("NUL")
	input, err := windows.CreateFile(nul, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, &sa, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		read.Close()
		return nil, err
	}
	defer windows.CloseHandle(input)
	job, err := NewJob()
	if err != nil {
		read.Close()
		return nil, err
	}
	p := &Command{job: job, read: read, copied: make(chan struct{})}
	ok := false
	defer func() {
		if !ok {
			p.Close()
		}
	}()
	attrs, err := windows.NewProcThreadAttributeList(2)
	if err != nil {
		return nil, err
	}
	defer attrs.Delete()
	handles := []windows.Handle{input, wr}
	if err = attrs.Update(windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, unsafe.Pointer(&handles[0]), uintptr(len(handles))*unsafe.Sizeof(handles[0])); err != nil {
		return nil, err
	}
	if err = attrs.Update(0x0002000d, unsafe.Pointer(&job), unsafe.Sizeof(job)); err != nil {
		return nil, err
	}
	si := windows.StartupInfoEx{}
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = windows.STARTF_USESTDHANDLES
	si.StdInput = input
	si.StdOutput = wr
	si.StdErr = wr
	si.ProcThreadAttributeList = attrs.List()
	quoted := []string{}
	for _, arg := range args {
		quoted = append(quoted, windows.EscapeArg(arg))
	}
	line, err := windows.UTF16FromString(strings.Join(quoted, " "))
	if err != nil {
		return nil, err
	}
	dir, err := windows.UTF16PtrFromString(cwd)
	if err != nil {
		return nil, err
	}
	block, err := environmentBlock(env)
	if err != nil {
		return nil, err
	}
	var pi windows.ProcessInformation
	err = windows.CreateProcess(nil, &line[0], nil, nil, true, windows.CREATE_NO_WINDOW|windows.EXTENDED_STARTUPINFO_PRESENT|windows.CREATE_UNICODE_ENVIRONMENT, &block[0], dir, &si.StartupInfo, &pi)
	if err != nil {
		return nil, err
	}
	windows.CloseHandle(pi.Thread)
	p.process = pi.Process
	ok = true
	go func() { defer close(p.copied); _, _ = io.Copy(out, read) }()
	return p, nil
}
func (p *Command) Wait() error {
	_, err := windows.WaitForSingleObject(p.process, windows.INFINITE)
	if err != nil {
		return err
	}
	var code uint32
	err = windows.GetExitCodeProcess(p.process, &code)
	p.Kill(true)
	<-p.copied
	if err != nil {
		return err
	}
	if code != 0 {
		return &ExitError{int(code)}
	}
	return nil
}
func (p *Command) Kill(bool) {
	p.killOnce.Do(func() {
		if p.job != 0 {
			_ = windows.TerminateJobObject(p.job, 1)
		}
	})
}
func (p *Command) Close() {
	p.closeOnce.Do(func() {
		p.Kill(true)
		if p.job != 0 {
			windows.CloseHandle(p.job)
		}
		if p.read != nil {
			p.read.Close()
		}
		if p.process != 0 {
			windows.CloseHandle(p.process)
		}
	})
}
