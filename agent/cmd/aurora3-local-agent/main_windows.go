// aurora3-local-agent is the Windows client-owned execution backend. It never
// registers with SCM, accepts remote binds, or uses the Linux installer.
package main

import (
	"aurora3/internal/ai"
	"aurora3/internal/devtools"
	"aurora3/internal/entry"
	"aurora3/internal/files"
	gitservice "aurora3/internal/git"
	"aurora3/internal/monitor"
	"aurora3/internal/proxysvc"
	"aurora3/internal/service"
	"aurora3/internal/statecrypt"
	"aurora3/internal/terminal"
	"aurora3/internal/winlocal"
	"aurora3/internal/wire"
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

var Version = "3.0.0-dev"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "version" {
		fmt.Println(Version)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "clone-protected-preview" {
		if err := cloneProtectedPreview(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "clone-client-preview" {
		if err := cloneClientPreview(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("已发布独立客户端加密克隆；未启动或更改源客户端")
		return
	}
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "unknown local-agent command")
		os.Exit(2)
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
		StateDir  string `json:"state_dir"`
		Protected bool   `json:"protected_state"`
	}
	if json.Unmarshal(line, &boot) != nil || !filepath.IsAbs(boot.StateDir) {
		return fmt.Errorf("本地状态目录无效")
	}
	// Refuse mode mismatches before touching ACLs or creating a writer lock
	// in an existing profile. Recheck admission under the writer lock below.
	if root, err := statecrypt.OpenStateDir(boot.StateDir); err == nil {
		root.Close()
		protected, err := statecrypt.HasKeyFile(boot.StateDir)
		if err != nil || (!boot.Protected && protected) {
			return errors.New("状态已受保护或无法验证；拒绝以兼容模式启动")
		}
		if boot.Protected && !protected {
			if err := statecrypt.CheckNewDir(boot.StateDir); err != nil {
				return err
			}
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err = privateDir(boot.StateDir); err != nil {
		return err
	}
	unlock, err := statecrypt.LockWriter(boot.StateDir)
	if err != nil {
		return fmt.Errorf("本地状态已被另一个进程占用或写入锁无法验证：%w", err)
	}
	defer unlock()
	if boot.Protected {
		protection, err := entry.PrepareLocalProtection(boot.StateDir)
		if err != nil {
			return fmt.Errorf("无法打开受保护本地状态（原件未重置）：%w", err)
		}
		if err := statecrypt.Activate(protection); err != nil {
			return err
		}
	} else if protected, err := statecrypt.HasKeyFile(boot.StateDir); err != nil || protected {
		return errors.New("状态已受保护或无法验证；拒绝以兼容模式启动")
	}
	job, err := winlocal.BindSelf()
	if err != nil {
		return err
	}
	defer windows.CloseHandle(job)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _, _ = io.Copy(io.Discard, in); cancel() }()
	roots, err := localRoots()
	if err != nil {
		return err
	}
	token := wire.NewToken()
	cfg := &entry.Config{Kind: "local", Name: "本机 Windows", Listen: "127.0.0.1:0", StateDir: boot.StateDir, Token: token, Roots: roots}
	// Only durable service choices are restored. Listener identity, auth token,
	// roots and loopback binding are freshly derived for this client-owned run.
	configPath := filepath.Join(boot.StateDir, "local-agent.json")
	if saved, err := entry.LoadLocalOptions(configPath); err == nil {
		cfg.Services, cfg.Proxy = saved.Services, saved.Proxy
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("读取本地 agent 服务配置失败：%w", err)
	}
	if err = cfg.Validate(); err != nil {
		return err
	}
	fe := &files.Env{StateDir: boot.StateDir, UploadMaxBytes: 64 << 30, Audit: entry.NewAudit("")}
	var srv *entry.Server
	px := &proxysvc.Env{
		Load: func() proxysvc.State {
			var state proxysvc.State
			if srv != nil {
				_ = json.Unmarshal(srv.ProxyRaw(), &state)
			}
			return state
		},
		Save: func(state proxysvc.State) error {
			raw, err := json.Marshal(state)
			if err != nil {
				return err
			}
			return srv.SaveProxyRaw(raw)
		},
		Enabled: func() bool { return srv != nil && srv.ServiceEnabled("proxy") },
		Audit:   fe.Audit, Log: log.New(os.Stderr, "", log.LstdFlags),
	}
	defer px.Close()
	ge := &gitservice.Env{Audit: fe.Audit, Proxy: winlocal.ProxyEnv}
	ae := &ai.Env{StateDir: boot.StateDir, Audit: fe.Audit, Proxy: winlocal.ProxyEnv, AgentProxy: px.GitEnv}
	te := &terminal.Env{Proxy: px.SessionEnv}
	me := &monitor.Env{Audit: fe.Audit}
	de := &devtools.Env{StateDir: boot.StateDir, Audit: fe.Audit, Proxy: winlocal.ProxyEnv}
	for _, r := range roots {
		fe.Roots = append(fe.Roots, files.Root{ID: r.ID, Label: r.Label, Path: r.Path})
		ge.Roots = append(ge.Roots, gitservice.Root{ID: r.ID, Label: r.Label, Path: r.Path})
		ae.Roots = append(ae.Roots, ai.Root{ID: r.ID, Label: r.Label, Path: r.Path})
		te.Roots = append(te.Roots, terminal.Root{ID: r.ID, Path: r.Path})
		de.Roots = append(de.Roots, devtools.Root{ID: r.ID, Path: r.Path})
	}
	fe.Repos = gitservice.Repos{Proxy: winlocal.ProxyEnv}
	defer te.Close()
	defer ae.StopAll()
	srv, err = entry.New(cfg, configPath, Version, []service.Service{fe.Service(), ge.Service(), te.Service(), ae.Service(), me.Service(), px.Service(), de.Service()}, func(s string) error { _, err := exec.LookPath(s); return err }, nil, log.New(os.Stderr, "", log.LstdFlags))
	if err != nil {
		return err
	}
	px.Start()
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
	if err = json.NewEncoder(os.Stdout).Encode(map[string]any{"kind": "local", "platform": "windows", "addr": addr, "pin": srv.Pin(), "token": token, "roots": roots, "version": Version, "protected_state": boot.Protected}); err != nil {
		return err
	}
	return <-done
}

func localRoots() ([]entry.Root, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	roots := []entry.Root{{ID: "home", Label: "用户目录", Path: home}}
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return nil, err
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
	return roots, nil
}
func privateDir(dir string) error {
	if fi, err := os.Lstat(dir); err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		if p, err := statecrypt.OpenStateDir(filepath.Dir(dir)); err != nil {
			return err
		} else {
			p.Close()
		}
	} else if !fi.IsDir() {
		return errors.New("本地状态目录不是普通目录")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	return statecrypt.PrivateDirectory(dir)
}
