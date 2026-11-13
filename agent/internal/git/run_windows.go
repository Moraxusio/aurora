package git

import (
	"aurora3/internal/paths"
	"aurora3/internal/wire"
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

type gitCtx struct {
	exe, dir string
	env      []string
}

func hideGitWindow(cmd *exec.Cmd)            { cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true} }
func ignoreOwner(string, *gitCtx) (int, int) { return -1, -1 }

var errNoGit = wire.Errf(wire.CodeUnsupported, "未找到 Git for Windows，请安装后重启 Aurora")

func gitFor(dir string, proxy func() map[string]string) (*gitCtx, error) {
	exe, err := exec.LookPath("git")
	if err != nil {
		return nil, errNoGit
	}
	env := append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=never")
	if proxy != nil {
		for k, v := range proxy() {
			env = append(env, k+"="+v)
		}
	}
	return &gitCtx{exe: exe, dir: dir, env: env}, nil
}
func (g *gitCtx) run(ctx context.Context, stdin []byte, args ...string) ([]byte, string, error) {
	args = append([]string{"-c", "core.quotepath=off", "-c", "color.ui=false", "-c", "core.pager=cat"}, args...)
	cmd := exec.CommandContext(ctx, g.exe, args...)
	cmd.Dir = g.dir
	cmd.Env = g.env
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	return out.Bytes(), strings.TrimSpace(errb.String()), err
}
func gitErr(stderr string, err error) error {
	if stderr == "" && err != nil {
		stderr = err.Error()
	}
	if len(stderr) > 4000 {
		stderr = stderr[len(stderr)-4000:]
	}
	return wire.Errf(wire.CodeConflict, "Git 操作失败：%s", stderr)
}
func rootRel(root, p string) string {
	if !paths.Within(root, p) {
		return ""
	}
	rel, _ := filepath.Rel(root, p)
	if rel == "." {
		return "/"
	}
	return "/" + filepath.ToSlash(rel)
}
