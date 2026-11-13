// aurora3-local-agent is the Windows client-owned execution backend. It never
// registers with SCM, accepts remote binds, or uses the Linux installer.
package main

import (
	"aurora3/internal/ai"
	"aurora3/internal/entry"
	"aurora3/internal/files"
	gitservice "aurora3/internal/git"
	"aurora3/internal/service"
	"aurora3/internal/terminal"
	"aurora3/internal/winlocal"
	"aurora3/internal/wire"
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
)

var Version = "3.0.0-dev"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "version" {
		fmt.Println(Version)
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "本地 agent:", err)
		os.Exit(1)
	}
}
func run() error {
	in := bufio.NewReader(io.LimitReader(os.Stdin, 1<<20))
	line, err := in.ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("缺少客户端启动配置")
	}
	var boot struct {
		StateDir string `json:"state_dir"`
	}
	if json.Unmarshal(line, &boot) != nil || !filepath.IsAbs(boot.StateDir) {
		return fmt.Errorf("本地状态目录无效")
	}
	if err = privateDir(boot.StateDir); err != nil {
		return err
	}
	job, err := winlocal.BindSelf()
	if err != nil {
		return err
	}
	defer windows.CloseHandle(job)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _, _ = io.Copy(io.Discard, in); cancel() }()
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	roots := []entry.Root{{ID: "home", Label: "用户目录", Path: home}}
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return err
	}
	for n := 0; n < 26; n++ {
		if mask&(1<<n) == 0 {
			continue
		}
		p := fmt.Sprintf("%c:\\", 'A'+n)
		u, _ := windows.UTF16PtrFromString(p)
		if windows.GetDriveType(u) == windows.DRIVE_FIXED {
			roots = append(roots, entry.Root{ID: strings.ToLower(p[:1]), Label: p, Path: p})
		}
	}
	token := wire.NewToken()
	cfg := &entry.Config{Kind: "local", Name: "本机 Windows", Listen: "127.0.0.1:0", StateDir: boot.StateDir, Token: token, Roots: roots}
	if err = cfg.Validate(); err != nil {
		return err
	}
	fe := &files.Env{UploadMaxBytes: 64 << 30, Audit: entry.NewAudit("")}
	ge := &gitservice.Env{Audit: fe.Audit, Proxy: winlocal.ProxyEnv}
	ae := &ai.Env{StateDir: boot.StateDir, Audit: fe.Audit, Proxy: winlocal.ProxyEnv}
	te := &terminal.Env{}
	for _, r := range roots {
		fe.Roots = append(fe.Roots, files.Root{ID: r.ID, Label: r.Label, Path: r.Path})
		ge.Roots = append(ge.Roots, gitservice.Root{ID: r.ID, Label: r.Label, Path: r.Path})
		ae.Roots = append(ae.Roots, ai.Root{ID: r.ID, Label: r.Label, Path: r.Path})
		te.Roots = append(te.Roots, terminal.Root{ID: r.ID, Path: r.Path})
	}
	fe.Repos = gitservice.Repos{Proxy: winlocal.ProxyEnv}
	defer te.Close()
	defer ae.StopAll()
	srv, err := entry.New(cfg, "", Version, []service.Service{fe.Service(), ge.Service(), te.Service(), ae.Service()}, func(s string) error { _, err := exec.LookPath(s); return err }, nil, log.New(os.Stderr, "", log.LstdFlags))
	if err != nil {
		return err
	}
	ready := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- srv.Run(ctx, ready) }()
	select {
	case err := <-done:
		return err
	case <-ready:
	case <-ctx.Done():
		return nil
	}
	addr := srv.Addr().String()
	if err = json.NewEncoder(os.Stdout).Encode(map[string]any{"kind": "local", "platform": "windows", "addr": addr, "pin": srv.Pin(), "token": token, "roots": roots, "version": Version}); err != nil {
		return err
	}
	return <-done
}
func privateDir(dir string) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	u, err := user.Current()
	if err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + u.Uid + ")")
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}
