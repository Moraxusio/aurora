//go:build linux

// aurora3-brokenagent is a test tool that stands in for a bad release
// (agent/tools/install-real.sh). Its installer is the real one, but as a
// service it exits at once, so the confirm stage fails and the install must
// roll back to what ran before.
package main

import (
	"flag"
	"fmt"
	"os"

	"aurora3/internal/install"
)

var Version = "3.0.3"

func main() {
	if len(os.Args) < 2 {
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(Version)
	case "install":
		fs := flag.NewFlagSet("install", flag.ExitOnError)
		sum := fs.String("sha256", "", "")
		name := fs.String("name", "", "")
		_ = fs.Parse(os.Args[2:])
		self, _ := os.Executable()
		e := &install.Env{Root: "/", Sys: install.Systemd{}, Dial: install.DialAgent, Self: self, Version: Version,
			Roots: install.DefaultRoots, Out: os.Stdout}
		os.Exit(install.ExitCode(install.Run(e, install.Options{SHA256: *sum, Name: *name})))
	default:
		fmt.Fprintln(os.Stderr, "broken on purpose")
		os.Exit(1)
	}
}
