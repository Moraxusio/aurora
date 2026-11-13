package ai

import (
	"aurora3/internal/winlocal"
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

func quietCommandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}
func shellEnvironment() []string { return winlocal.Merge(os.Environ(), winlocal.ProxyEnv()) }
func startShellCommand(command, cwd string, env []string, out io.Writer) (shellProcess, error) {
	return winlocal.StartCommand([]string{winlocal.Shell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); $OutputEncoding = [Console]::OutputEncoding; " + command}, cwd, env, out)
}
