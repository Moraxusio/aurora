package files

import (
	"aurora3/internal/service"
	"context"
	"encoding/json"
)

func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ e *Env }

func (svc) ID() string                         { return "files" }
func (svc) Dependencies() []service.Dependency { return nil }
func (v svc) Operations() []service.Operation {
	e := v.e
	return []service.Operation{
		{Name: "fs.roots", Handle: func(context.Context, json.RawMessage) (any, error) {
			return map[string]any{"roots": e.rootsInfo()}, nil
		}},
		{Name: "fs.list", Handle: e.fsList}, {Name: "fs.stat", Handle: e.fsStat}, {Name: "fs.read", Handle: e.fsRead}, {Name: "fs.write", Handle: e.fsWrite},
		{Name: "fs.mkdir", Handle: e.fsMkdir}, {Name: "fs.rename", Handle: e.fsRename}, {Name: "fs.copy", Handle: e.fsCopy}, {Name: "fs.delete", Handle: e.fsDelete},
		{Name: "fs.upload", Stream: e.fsUpload}, {Name: "fs.download", Stream: e.fsDownload}, {Name: "fs.watch", Stream: e.fsWatch},
		{Name: "fs.search", Handle: e.fsSearch}, {Name: "fs.find", Handle: e.fsFind},
	}
}
