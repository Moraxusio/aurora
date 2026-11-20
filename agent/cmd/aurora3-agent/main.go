// aurora3-agent is Aurora's server side (v3). It runs beside a v2 aurora-agent
// without sharing any name, path or port (D-71).
//
//	aurora3-agent version
//	aurora3-agent run [--config /etc/aurora3/agent.json]
//	aurora3-agent install --sha256 HEX [--name N] [--user U] [--probe] [--instance I]
//	aurora3-agent direct-info [--instance I]
//	aurora3-agent uninstall [--probe] [--force] [--purge] [--instance I]
package main

import (
	"flag"
	"fmt"
	"os"

	"aurora3/internal/update"
)

// Version is set at build time with -ldflags "-X main.Version=...".
var Version = "3.0.0-dev"

func commandAllowed(command string) bool {
	if releaseChannel != update.ChannelPreview {
		return true
	}
	switch command {
	case "version", "run", "init-protected-preview", "clone-protected-preview", "activation-preview", "activation-probe-child":
		return true
	default:
		return false
	}
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	if !commandAllowed(os.Args[1]) {
		fmt.Fprintln(os.Stderr, "公开预览不支持系统服务安装、升级或卸载")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(Version)
	case "run":
		fs := flag.NewFlagSet("run", flag.ExitOnError)
		fallback := defaultConfigPath
		if releaseChannel == update.ChannelPreview {
			fallback = ""
		}
		cfg := fs.String("config", fallback, "配置文件")
		_ = fs.Parse(os.Args[2:])
		if *cfg == "" || fs.NArg() != 0 {
			usage()
		}
		if err := run(*cfg); err != nil {
			fmt.Fprintln(os.Stderr, "aurora3-agent:", err)
			os.Exit(1)
		}
	case "install":
		os.Exit(installCmd(os.Args[2:]))
	case "direct-info":
		os.Exit(directInfoCmd(os.Args[2:]))
	case "init-protected-preview":
		if err := initProtectedPreview(os.Args[2:], os.Stdin); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "clone-protected-preview":
		if err := cloneProtectedPreview(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "activation-preview":
		if err := activationPreview(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "activation-probe-child":
		if len(os.Args) != 4 || activationProbeChild(os.Args[2], os.Args[3]) != nil {
			os.Exit(1)
		}
	case "uninstall":
		os.Exit(uninstallCmd(os.Args[2:]))
	case "upgrade-worker":
		// upgrade-worker DIR [INSTANCE]
		if len(os.Args) != 3 && len(os.Args) != 4 {
			os.Exit(2)
		}
		instance := ""
		if len(os.Args) == 4 {
			instance = os.Args[3]
		}
		if err := upgradeWorker(os.Args[2], instance); err != nil {
			fmt.Fprintln(os.Stderr, "升级任务失败，请查看任务状态")
			os.Exit(1)
		}
	default:
		usage()
	}
}

func usage() {
	if releaseChannel == update.ChannelPreview {
		fmt.Fprintln(os.Stderr, "usage: aurora3-agent version | init-protected-preview --dest PATH --instance NAME < private-token-input | clone-protected-preview | run --config PATH | activation-preview")
		os.Exit(2)
	}
	fmt.Fprintln(os.Stderr, "usage: aurora3-agent version | run [--config PATH] | install --sha256 HEX [--name N] [--user U] [--probe] [--instance I] | direct-info [--instance I] | uninstall [--probe] [--force] [--purge] [--instance I]")
	os.Exit(2)
}
