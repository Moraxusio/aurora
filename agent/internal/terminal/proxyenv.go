//go:build linux

package terminal

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"aurora3/internal/wire"
)

// proxyVars asks the proxy service for the session environment. The refusal
// is the user's to read: a session with proxy:true never silently starts
// without one (D-49).
func (e *Env) proxyVars() (map[string]string, error) {
	if e.Proxy == nil {
		return nil, wire.Errf(wire.CodeUnavailable, "这台服务器没有代理服务")
	}
	vars, err := e.Proxy()
	if err != nil {
		return nil, wire.Errf(wire.CodeUnavailable, "%v", err)
	}
	return vars, nil
}

// writeSessionEnv writes the variables to a 0600 file only the agent's user can
// read, in a directory only that user can enter, and returns its path. The
// file name is random: it is not derived from the session name, so one session
// cannot guess another's.
func (e *Env) writeSessionEnv(session string, vars map[string]string) (string, error) {
	dir := filepath.Join(e.StateDir, "session-env")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	// A crash can leave a file behind: this is a short list that is cleaned at
	// every start of a session, not a place that grows.
	if old, err := os.ReadDir(dir); err == nil {
		for _, f := range old {
			if info, err := f.Info(); err == nil && time.Since(info.ModTime()) > 5*time.Minute {
				_ = os.Remove(filepath.Join(dir, f.Name()))
			}
		}
	}
	var r [12]byte
	if _, err := rand.Read(r[:]); err != nil {
		return "", err
	}
	path := filepath.Join(dir, hex.EncodeToString(r[:]))
	keys := make([]string, 0, len(vars))
	for k := range vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("# aurora3: this session's proxy settings. Read once at the start, then deleted.\n")
	for _, k := range keys {
		if !envKey(k) {
			continue
		}
		b.WriteString("export " + k + "=" + shellQuote(vars[k]) + "\n")
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	if _, err := f.WriteString(b.String()); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	return path, f.Close()
}

// sessionRC is bash's startup file for a proxied session. It reads the user's
// own ~/.bashrc first, as an interactive shell would, then the session's proxy
// variables, so a proxy line in the user's files cannot undo the choice made
// when the session was created. It deletes the variables file after reading it.
const sessionRC = `# aurora3: startup of a session made with the proxy on. Do not edit.
[ -f ~/.bashrc ] && . ~/.bashrc
if [ -n "${AURORA3_ENVFILE:-}" ] && [ -r "$AURORA3_ENVFILE" ]; then
  . "$AURORA3_ENVFILE"
  rm -f "$AURORA3_ENVFILE"
fi
unset AURORA3_ENVFILE AURORA3_RC
`

// writeSessionRC writes sessionRC once and returns its path. It holds no
// secret, so any process may read it; it is the same file for every session.
func (e *Env) writeSessionRC() (string, error) {
	dir := filepath.Join(e.StateDir, "session-env")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(e.StateDir, "session.bashrc")
	if b, err := os.ReadFile(path); err == nil && string(b) == sessionRC {
		return path, nil
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(sessionRC), 0o644); err != nil {
		return "", err
	}
	return path, os.Rename(tmp, path)
}

// envKey allows only names a shell can export, so a variable name can never
// carry shell syntax into the file.
func envKey(k string) bool {
	if k == "" {
		return false
	}
	for i, c := range k {
		switch {
		case c == '_', c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z':
		case c >= '0' && c <= '9' && i > 0:
		default:
			return false
		}
	}
	return true
}
