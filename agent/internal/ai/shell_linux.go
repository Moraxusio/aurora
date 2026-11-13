package ai

import (
	"context"
	"io"
	"os"
	"os/exec"
	"syscall"
)

type shellProcess interface {
	Wait() error
	Kill(bool)
	Close()
}
type linuxShell struct{ cmd *exec.Cmd }

func quietCommandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, name, args...)
}
func shellEnvironment() []string { return os.Environ() }
func startShellCommand(command, cwd string, env []string, out io.Writer) (shellProcess, error) {
	shell := "/bin/bash"
	if _, err := os.Stat(shell); err != nil {
		shell = "sh"
	}
	cmd := exec.Command(shell, "-c", command)
	cmd.Dir = cwd
	cmd.Env = env
	cmd.Stdout = out
	cmd.Stderr = out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &linuxShell{cmd}, nil
}
func (p *linuxShell) Wait() error { return p.cmd.Wait() }
func (p *linuxShell) Kill(force bool) {
	sig := syscall.SIGTERM
	if force {
		sig = syscall.SIGKILL
	}
	_ = syscall.Kill(-p.cmd.Process.Pid, sig)
}
func (p *linuxShell) Close() {}
