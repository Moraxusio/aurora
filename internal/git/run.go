//go:build linux

package git

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"

	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

type gitCtx struct {
	exe  string
	dir  string
	cred *syscall.Credential
	home string
	name string
	env  []string
}

var errNoGit = wire.Errf(wire.CodeUnsupported, "服务器上没有安装 git")

// gitFor prepares git for dir. proxy, when non-nil and returning a map, adds the
// proxy variables to git's environment (D-69).
func gitFor(dir string, proxy func() map[string]string) (*gitCtx, error) {
	exe, err := exec.LookPath("git")
	if err != nil {
		return nil, errNoGit
	}
	g := &gitCtx{exe: exe, dir: dir, home: "/root", name: "root"}
	if fi, err := os.Stat(dir); err == nil {
		if st, ok := fi.Sys().(*syscall.Stat_t); ok && st.Uid != 0 && os.Geteuid() == 0 {
			if u, err := user.LookupId(strconv.Itoa(int(st.Uid))); err == nil {
				gid, _ := strconv.Atoi(u.Gid)
				cred := &syscall.Credential{Uid: st.Uid, Gid: uint32(gid)}
				if ids, err := u.GroupIds(); err == nil {
					for _, id := range ids {
						if n, err := strconv.Atoi(id); err == nil {
							cred.Groups = append(cred.Groups, uint32(n))
						}
					}
				}
				g.cred, g.home, g.name = cred, u.HomeDir, u.Username
			}
		}
	}
	g.env = []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=" + g.home, "USER=" + g.name, "LOGNAME=" + g.name, "LANG=C.UTF-8",
		"GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=/bin/false", "SSH_ASKPASS=/bin/false",
		"GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=20",
	}
	if proxy != nil {
		for k, v := range proxy() {
			g.env = append(g.env, k+"="+v)
		}
	}
	return g, nil
}

// run runs git in g.dir; stdin may be nil.
func (g *gitCtx) run(ctx context.Context, stdin []byte, args ...string) ([]byte, string, error) {
	full := append([]string{"-c", "safe.directory=*", "-c", "core.quotepath=off", "-c", "color.ui=false", "-c", "core.pager=cat"}, args...)
	cmd := exec.CommandContext(ctx, g.exe, full...)
	cmd.Dir = g.dir
	cmd.Env = g.env
	if g.cred != nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: g.cred}
	}
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	return out.Bytes(), strings.TrimSpace(errb.String()), err
}

// gitErr turns a failed git command into a message the user can act on.
func gitErr(stderr string, err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return wire.Errf(wire.CodeUnavailable, "git 超时")
	}
	msg := stderr
	if msg == "" && err != nil {
		msg = err.Error()
	}
	switch {
	case strings.Contains(msg, "Please tell me who you are"), strings.Contains(msg, "empty ident"):
		msg = "还没有设置提交者身份。在终端里运行：git config --global user.name \"你的名字\" 和 git config --global user.email \"你的邮箱\""
	case strings.Contains(msg, "terminal prompts disabled"), strings.Contains(msg, "could not read Username"):
		msg = "远程仓库需要登录。请在终端里配置凭据（SSH 密钥或 git credential），然后重试。\n" + msg
	case strings.Contains(msg, "would be overwritten by"):
		msg = "本地有未提交的更改会被覆盖。先提交或储藏这些更改，再重试。\n" + msg
	case strings.Contains(msg, "Not possible to fast-forward"), strings.Contains(msg, "divergent branches"):
		msg = "本地和远程各有新的提交，需要选择合并或变基。\n" + msg
	case strings.Contains(msg, "[rejected]") && (strings.Contains(msg, "fetch first") || strings.Contains(msg, "non-fast-forward")):
		msg = "远程有你本地没有的新提交，推送被拒绝。先同步（拉取）再推送。\n" + msg
	case strings.Contains(msg, "Permission denied (publickey"):
		msg = "SSH 密钥被拒绝：这台服务器上的密钥没有这个仓库的权限。\n" + msg
	}
	if len(msg) > 4000 {
		msg = msg[len(msg)-4000:]
	}
	return wire.Errf(wire.CodeConflict, "%s", msg)
}

// dirOf resolves {root, path} to a real folder inside that root.

// gitErr turns git's stderr into the message the client shows. Copied from v2
// gitrun.go; these texts are part of the user-facing behaviour.

// rootRel returns p relative to rootAbs, or "" when p is outside it.
func rootRel(rootAbs, p string) string {
	if !paths.Within(rootAbs, p) {
		return ""
	}
	r := strings.TrimPrefix(p, strings.TrimSuffix(rootAbs, "/"))
	if r == "" {
		return "/"
	}
	return r
}
