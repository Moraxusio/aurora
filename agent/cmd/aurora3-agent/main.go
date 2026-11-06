// aurora3-agent is Aurora's server side (v3). It runs beside a v2 aurora-agent
// without sharing any name, path or port (D-71).
//
//	aurora3-agent version
//	aurora3-agent run [--config /etc/aurora3/agent.json]
//	aurora3-agent install --sha256 HEX [--name N] [--user U] [--probe]
//	aurora3-agent direct-info
package main

import (
	"flag"
	"fmt"
	"os"
)

// Version is set at build time with -ldflags "-X main.Version=...".
var Version = "3.0.0-dev"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(Version)
	case "run":
		fs := flag.NewFlagSet("run", flag.ExitOnError)
		cfg := fs.String("config", defaultConfigPath, "配置文件")
		_ = fs.Parse(os.Args[2:])
		if err := run(*cfg); err != nil {
			fmt.Fprintln(os.Stderr, "aurora3-agent:", err)
			os.Exit(1)
		}
	case "install":
		os.Exit(installCmd(os.Args[2:]))
	case "direct-info":
		os.Exit(directInfoCmd(os.Args[2:]))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: aurora3-agent version | run [--config PATH] | install --sha256 HEX [--name N] [--user U] [--probe] | direct-info")
	os.Exit(2)
}
