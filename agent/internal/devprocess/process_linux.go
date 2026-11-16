package devprocess

import (
	"os"
	"os/exec"
	"sync"
	"syscall"
)

type linuxChild struct {
	cmd  *exec.Cmd
	kill sync.Once
}

func start(args []string, cwd string, env []string, in, out, stderr *os.File) (child, error) {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir, cmd.Env = cwd, env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = in, out, stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &linuxChild{cmd: cmd}, nil
}
func (p *linuxChild) Wait() error { err := p.cmd.Wait(); p.Kill(true); return err }
func (p *linuxChild) Kill(bool) {
	p.kill.Do(func() { _ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL) })
}
func (p *linuxChild) Close() { p.Kill(true) }
