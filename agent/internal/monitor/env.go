//go:build linux

package monitor

import (
	"encoding/json"
	"os"
	"runtime"
	"strings"

	"aurora3/internal/wire"
)

// Env is what the monitor service needs from the agent: the audit writer, the
// roots, and the process sampler's state between two calls (D-26, D-40).
type Env struct {
	Roots   []Root
	Audit   Auditor
	sampler *procSampler
}

// Root is one folder a client may browse.
type Root struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
}

// Auditor records one line per mutating operation (D-26).
type Auditor interface {
	Write(event string, fields map[string]any)
}

// decode reads the operation's arguments (copied from v2 server.go).
func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

// osName describes the operating system (copied from v2 server.go).
func osName() string {
	b, err := os.ReadFile("/etc/os-release")
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
				return strings.Trim(v, "\"")
			}
		}
	}
	return runtime.GOOS
}
