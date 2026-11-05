//go:build linux

// Package files serves the "files" service: browsing, reading, writing and
// transferring files inside the configured roots. The code in files.go is the
// v2 implementation with its receiver changed from *Server to *Env, so the
// service needs only the three things it used from the server.
package files

import (
	"encoding/json"

	"aurora3/internal/wire"
)

// Root is one folder a client may browse. The agent refuses any path that
// resolves outside it (os.Root).
type Root struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
}

// Auditor records one line per mutating operation (D-26).
type Auditor interface {
	Write(event string, fields map[string]any)
}

// Env is everything the files service needs from the agent.
type Env struct {
	Roots          []Root
	UploadMaxBytes int64
	Audit          Auditor
}

func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}
