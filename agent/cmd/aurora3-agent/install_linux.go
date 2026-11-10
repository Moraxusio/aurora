//go:build linux

package main

import (
	"flag"
	"os"
	"os/signal"
	"syscall"

	"aurora3/internal/entry"
	"aurora3/internal/install"
	"aurora3/internal/update"
)

// installCmd: aurora3-agent install --sha256 HEX [--name N] [--user U] [--probe]
//
// The client runs it as root over SSH after uploading this binary (D-3). It
// prints JSON lines (progress, then the result) and exits 0 on success, 1
// when it refused and changed nothing, 2 after a rollback, 3 when the
// rollback did not finish.
func installCmd(args []string) int {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	sum := fs.String("sha256", "", "本程序的 SHA-256（来自签名清单）")
	name := fs.String("name", "", "服务器名称（仅新安装）")
	user := fs.String("user", "", "其主目录作为第一个文件根目录（仅新安装）")
	probe := fs.Bool("probe", false, "只探测，不做改动")
	instance := fs.String("instance", "", instanceHelp)
	policyFile := fs.String("policy", "", "签名撤回清单")
	policySig := fs.String("policy-signature", "", "撤回清单签名")
	_ = fs.Parse(args)
	detach()
	if !*probe && os.Geteuid() != 0 {
		install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: "安装需要 root 权限"})
		return 1
	}
	var policy *update.Policy
	if *policyFile != "" || *policySig != "" {
		b, err := os.ReadFile(*policyFile)
		s, err2 := os.ReadFile(*policySig)
		if err != nil || err2 != nil {
			install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: "无法读取签名撤回清单"})
			return 1
		}
		p, err := update.VerifyPolicy(b, s)
		if err != nil {
			install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: err.Error()})
			return 1
		}
		policy = &p
	}
	r := install.Run(env(*instance), install.Options{SHA256: *sum, Name: *name, User: *user, ProbeOnly: *probe, Policy: policy})
	return install.ExitCode(r)
}

// uninstallCmd: aurora3-agent uninstall [--probe] [--force] [--purge]. Exits
// 0 when done, 1 when it refused (sessions without --force, or not root), 4
// when a step failed (what ran is reported; no rollback, D-34).
func uninstallCmd(args []string) int {
	fs := flag.NewFlagSet("uninstall", flag.ExitOnError)
	probe := fs.Bool("probe", false, "只列出会话和已安装的内容，不做改动")
	force := fs.Bool("force", false, "有终端会话时也卸载（会结束它们）")
	purge := fs.Bool("purge", false, "同时删除配置、证书、令牌和状态（彻底清除）")
	instance := fs.String("instance", "", instanceHelp)
	_ = fs.Parse(args)
	detach()
	if !*probe && os.Geteuid() != 0 {
		install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: "卸载需要 root 权限"})
		return 1
	}
	return install.UninstallExitCode(install.Uninstall(env(*instance), install.UninstallOptions{Probe: *probe, Force: *force, Purge: *purge}))
}

// directInfoCmd: aurora3-agent direct-info. Prints the installed agent's
// direct-link parameters, token included (D-4); root only, as agent.json is.
func directInfoCmd(args []string) int {
	fs := flag.NewFlagSet("direct-info", flag.ExitOnError)
	instance := fs.String("instance", "", instanceHelp)
	_ = fs.Parse(args)
	if os.Geteuid() != 0 {
		install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: "读取直连参数需要 root 权限"})
		return 1
	}
	return install.ExitCode(install.DirectInfo(env(*instance)))
}

const instanceHelp = "实例名（同一台服务器上的多个 agent，每个客户端一个；不填是默认实例）"

func env(instance string) *install.Env {
	socket := ""
	if l, err := entry.LayoutFor(instance); err == nil {
		socket = l.Socket // an invalid name is refused by the install package
	}
	self, err := os.Executable()
	if err != nil {
		self = os.Args[0]
	}
	return &install.Env{Root: "/", Instance: instance, Sys: install.Systemd{Socket: socket}, Dial: install.DialAgent, Self: self, Version: Version,
		Roots: install.DefaultRoots, Out: os.Stdout}
}

// detach keeps a run going when the SSH session that started it goes away:
// the hang-up is ignored, and writes to the closed pipe fail instead of
// killing the process. The four stages then finish or roll back on their own.
func detach() {
	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
}
