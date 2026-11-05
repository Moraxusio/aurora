//go:build linux

package files

import (
	"context"
	"encoding/json"

	"aurora3/internal/service"
)

// Service is the "files" service (D-45). Operation names are v2's
// (internal/agent/ops.go).
func (s *Env) Service() service.Service { return svc{s} }

type svc struct{ e *Env }

func (svc) ID() string { return "files" }

func (svc) Dependencies() []service.Dependency { return nil }

func (v svc) Operations() []service.Operation {
	e := v.e
	u := func(name string, h service.Handler) service.Operation {
		return service.Operation{Name: name, Handle: h}
	}
	st := func(name string, h service.StreamHandler) service.Operation {
		return service.Operation{Name: name, Stream: h}
	}
	return []service.Operation{
		u("fs.roots", func(context.Context, json.RawMessage) (any, error) {
			return map[string]any{"roots": e.rootsInfo()}, nil
		}),
		u("fs.list", e.fsList),
		u("fs.stat", e.fsStat),
		u("fs.du", e.fsDu),
		u("fs.read", e.fsRead),
		u("fs.write", e.fsWrite),
		u("fs.mkdir", e.fsMkdir),
		u("fs.rename", e.fsRename),
		u("fs.copy", e.fsCopy),
		u("fs.delete", e.fsDelete),
		st("fs.upload", e.fsUpload),
		st("fs.download", e.fsDownload),
		st("fs.watch", e.fsWatch),
		st("fs.tail", e.fsTail),
		u("fs.search", e.fsSearch),
		u("fs.find", e.fsFind),
		u("fs.logs", e.fsLogs),
	}
}
