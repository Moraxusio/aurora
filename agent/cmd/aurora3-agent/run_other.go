//go:build !linux

package main

import (
	"errors"
	"fmt"
	"os"
)

const defaultConfigPath = "/etc/aurora3/agent.json"

func run(string) error { return errors.New("aurora3-agent runs on Linux only") }

func installCmd([]string) int {
	fmt.Fprintln(os.Stderr, "aurora3-agent install runs on Linux only")
	return 1
}

func directInfoCmd([]string) int { return installCmd(nil) }

func uninstallCmd([]string) int { return installCmd(nil) }

func upgradeWorker(string) error { return errors.New("upgrade worker runs on Linux only") }
