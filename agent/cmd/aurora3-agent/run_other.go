//go:build !linux

package main

import "errors"

const defaultConfigPath = "/etc/aurora3/agent.json"

func run(string) error { return errors.New("aurora3-agent runs on Linux only") }
