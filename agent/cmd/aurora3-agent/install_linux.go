//go:build linux

package main

import (
	"flag"
	"os"
	"os/signal"
	"syscall"

	"aurora3/internal/install"
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
	_ = fs.Parse(args)
	detach()
	if !*probe && os.Geteuid() != 0 {
		install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: "安装需要 root 权限"})
		return 1
	}
	r := install.Run(env(), install.Options{SHA256: *sum, Name: *name, User: *user, ProbeOnly: *probe})
	return install.ExitCode(r)
}

// directInfoCmd: aurora3-agent direct-info. Prints the installed agent's
// direct-link parameters, token included (D-4); root only, as agent.json is.
func directInfoCmd([]string) int {
	if os.Geteuid() != 0 {
		install.Emit(os.Stdout, install.Result{Result: install.ResultRefused, Message: "读取直连参数需要 root 权限"})
		return 1
	}
	return install.ExitCode(install.DirectInfo(env()))
}

func env() *install.Env {
	self, err := os.Executable()
	if err != nil {
		self = os.Args[0]
	}
	return &install.Env{Root: "/", Sys: install.Systemd{}, Dial: install.DialAgent, Self: self, Version: Version,
		Roots: install.DefaultRoots, Out: os.Stdout}
}

// detach keeps a run going when the SSH session that started it goes away:
// the hang-up is ignored, and writes to the closed pipe fail instead of
// killing the process. The four stages then finish or roll back on their own.
func detach() {
	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
}
