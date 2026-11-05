//go:build linux

// Package git serves the "git" service: repository status, history, staging,
// commits, branches and remotes, run as the repository's owner (v2 gitrun.go).
package git

import (
	"encoding/json"

	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

// Root is one folder a client may work in. Its ID and path come from agent.json.
type Root struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Path  string `json:"path"`
}

// Auditor records one line per mutating operation (D-26).
type Auditor interface {
	Write(event string, fields map[string]any)
}

// Env is everything the git service needs from the agent.
type Env struct {
	Roots []Root
	Audit Auditor
}

// decode reads the operation's arguments. Copied from v2 server.go.
func decode(args json.RawMessage, v any) error {
	if len(args) == 0 || string(args) == "null" {
		return nil
	}
	if err := json.Unmarshal(args, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

// rootPath returns the configured path of root id, or the first root's path.
func (e *Env) rootPath(id string) string {
	for _, r := range e.Roots {
		if r.ID == id {
			return r.Path
		}
	}
	if len(e.Roots) > 0 {
		return e.Roots[0].Path
	}
	return "/"
}

// openRootPath checks that root id is configured and returns its path, or the
// error v2 gave for an unknown root.
func (e *Env) openRootPath(id string) (string, error) {
	for _, r := range e.Roots {
		if r.ID == id || (id == "" && len(e.Roots) > 0 && r.ID == e.Roots[0].ID) {
			return r.Path, nil
		}
	}
	return "", wire.Errf(wire.CodeNotFound, "未知的根目录：%s", id)
}

// dirOf resolves {root, path} to a real folder inside that root. Same rules and
// messages as the files service (internal/paths).
func (e *Env) dirOf(rootID, p string) (rootAbs, abs string, err error) {
	if _, err := paths.Clean(p); err != nil {
		return "", "", paths.WireError(err)
	}
	rootAbs, err = e.openRootPath(rootID)
	if err != nil {
		return "", "", err
	}
	abs, err = paths.Resolve(rootAbs, p)
	if err == paths.ErrOutside {
		return "", "", paths.WireError(err)
	}
	if err != nil {
		return "", "", wire.Errf(wire.CodeInternal, "%v", err)
	}
	return rootAbs, abs, nil
}