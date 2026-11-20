package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"aurora3/internal/activation"
	"aurora3/internal/entry"
	"aurora3/internal/install"
	"aurora3/internal/statecrypt"
	"aurora3/internal/wire"
)

// activationPreview never installs, edits or restarts a systemd unit. Each
// artifact SHA has a distinct, sealed clone so trial writes cannot touch the
// selected program's data. It is not the production upgrade path yet.
func activationPreview(args []string) error {
	if len(args) == 0 {
		return errors.New("activation-preview: init | trial | status | launch")
	}
	opts := flag.NewFlagSet(args[0], flag.ContinueOnError)
	root := opts.String("root", "", "私有隔离验收目录")
	version := opts.String("version", "", "候选版本")
	digest := opts.String("sha256", "", "已签名程序摘要")
	if err := opts.Parse(args[1:]); err != nil {
		return err
	}
	if opts.NArg() != 0 || os.Getenv("INVOCATION_ID") != "" {
		return errors.New("版本切换预览不接受额外参数或生产 systemd 启动")
	}
	dir, err := statecrypt.OpenStateDir(*root)
	if err != nil {
		return err
	}
	defer dir.Close()
	store := &activation.Store{Dir: filepath.Join(*root, "selection"), Verify: func(p activation.Program) error {
		_, err := activation.LinuxProgram(*root, p, releaseChannel)
		return err
	}}
	out := json.NewEncoder(os.Stdout)
	target := activation.Program{Version: *version, SHA256: *digest}
	switch args[0] {
	case "init":
		// Even the initial pointer requires a verified loopback handshake.
		return store.InitializeReady(target, func(p activation.Program) error {
			return trialIsolatedProgram(*root, p)
		})
	case "trial":
		current, err := store.ReadReceipt()
		if err != nil {
			return err
		}
		job, err := store.Trial(current.Active, target, func(p activation.Program) error {
			if err := samePairing(*root, current.Active, p); err != nil {
				return err
			}
			return trialIsolatedProgram(*root, p)
		})
		if err != nil {
			// Only persisted status is authoritative.
			return fmt.Errorf("试运行未确认，请查看 status：%w", err)
		}
		return out.Encode(job)
	case "status":
		status, err := store.ReadReceipt()
		if err != nil {
			return err
		}
		return out.Encode(status)
	case "launch":
		p, err := store.SelectOnBoot()
		if err != nil {
			return err
		}
		path, cfgPath, _, err := isolatedProgram(*root, p)
		if err != nil {
			return err
		}
		ctx, stop := signalContext()
		defer stop()
		cmd := exec.CommandContext(ctx, path, "run", "--config", cfgPath)
		cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
		cmd.WaitDelay = 5 * time.Second
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		return cmd.Run()
	default:
		return errors.New("未知版本切换预览操作")
	}
}

func samePairing(root string, current, target activation.Program) error {
	_, _, before, err := isolatedProgram(root, current)
	if err != nil {
		return err
	}
	_, _, after, err := isolatedProgram(root, target)
	if err != nil {
		return err
	}
	pin, id, err := isolatedPairing(before.StateDir)
	if err != nil {
		return err
	}
	pin2, id2, err := isolatedPairing(after.StateDir)
	if err != nil {
		return err
	}
	if pin != pin2 || id != id2 || !wire.TokenEqual(before.Token, after.Token) {
		return errors.New("候选状态不保留当前配对身份和凭据")
	}
	return nil
}

func isolatedPairing(dir string) (string, string, error) {
	r, err := statecrypt.OpenStateDir(dir)
	if err != nil {
		return "", "", err
	}
	defer r.Close()
	return entry.ValidatePreviewPairing(r)
}

func isolatedProgram(root string, p activation.Program) (string, string, *entry.Config, error) {
	bin, err := activation.LinuxProgram(root, p, releaseChannel)
	if err != nil {
		return "", "", nil, err
	}
	dir := filepath.Join(root, "fixtures", p.SHA256)
	checked, err := statecrypt.OpenStateDir(dir)
	if err != nil {
		return "", "", nil, err
	}
	checked.Close()
	path := filepath.Join(dir, "agent.json")
	cfg, err := entry.LoadConfig(path)
	if err != nil {
		return "", "", nil, err
	}
	if cfg.StateDir != dir || cfg.Protection() == nil {
		return "", "", nil, errors.New("试运行要求独立加密状态")
	}
	if err := checkIsolatedConfig(path, cfg); err != nil {
		return "", "", nil, err
	}
	return bin, path, cfg, nil
}

func checkIsolatedConfig(path string, cfg *entry.Config) error {
	if path != filepath.Join(cfg.StateDir, "agent.json") || cfg.Instance == "" ||
		cfg.Listen != "127.0.0.1:0" || cfg.AuditLog != "" || len(cfg.PublicAddrs) != 0 ||
		os.Getenv("INVOCATION_ID") != "" {
		return errors.New("受保护预览只支持手工启动具名回环实例")
	}
	state, err := statecrypt.OpenStateDir(cfg.StateDir)
	if err != nil {
		return err
	}
	state.Close()
	for _, r := range cfg.Roots {
		rel, err := filepath.Rel(filepath.Join(cfg.StateDir, "fixture-projects"), r.Path)
		if err != nil || rel == "." || !filepath.IsLocal(rel) {
			return errors.New("项目根必须位于隔离预览目录中")
		}
		target, err := statecrypt.OpenStateDir(r.Path)
		if err != nil {
			return err
		}
		target.Close()
	}
	return nil
}

func trialIsolatedProgram(root string, p activation.Program) error {
	bin, cfgPath, cfg, err := isolatedProgram(root, p)
	if err != nil {
		return err
	}
	// Certificate is public and already in the selected isolated state.
	pin, id, err := isolatedPairing(cfg.StateDir)
	if err != nil {
		return err
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	defer reader.Close()
	defer writer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	// Linux delivers Pdeathsig on death of the creating thread; keep that
	// thread alive until Wait completes, including error paths.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	cmd := exec.CommandContext(ctx, bin, "activation-probe-child", cfgPath, strconv.Itoa(os.Getpid()))
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	cmd.ExtraFiles = []*os.File{writer}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return err
	}
	_ = writer.Close()
	done := false
	defer func() {
		if !done {
			cancel()
			_ = cmd.Wait()
		}
	}()
	var ready activationReady
	reply := make(chan error, 1)
	go func() { reply <- json.NewDecoder(io.LimitReader(reader, 4096)).Decode(&ready) }()
	select {
	case err := <-reply:
		if err != nil {
			return err
		}
	case <-ctx.Done():
		return ctx.Err()
	}
	host, port, err := net.SplitHostPort(ready.Address)
	if err != nil || host != "127.0.0.1" || port == "0" || ready.Pin != pin {
		return errors.New("候选监听或证书指纹不匹配")
	}
	info, err := install.DialAgent(ctx, ready.Address, pin, cfg.Token)
	if err != nil || info.ID != id || info.Version != p.Version {
		return errors.New("候选未能验证原配对、认证和版本")
	}
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		return err
	}
	err = cmd.Wait()
	done = true
	return err
}

func activationProbeChild(path, parent string) error {
	if strconv.Itoa(os.Getppid()) != parent || os.Getppid() <= 1 {
		return errors.New("试运行父进程已经退出")
	}
	announce := os.NewFile(3, "activation-ready")
	if announce == nil {
		return errors.New("缺少试运行父进程")
	}
	defer announce.Close()
	return runReady(path, announce)
}
