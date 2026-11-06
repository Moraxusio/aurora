// Package bundle embeds the tmux build that ships inside aurora3-agent
// (agent/tools/tmux): tmux.gz, terminfo.tar.gz and manifest.txt. The files
// are build outputs and not in git; agent/tools/tmux/bundle.lock pins their
// SHA-256. A checkout without them embeds only .gitkeep, and the terminal
// service then falls back to the system tmux.
package bundle

import "embed"

// all:* matches whatever is present, so a checkout without the build
// (only .gitkeep, and this file) still compiles.
//
//go:embed all:*
var files embed.FS

// FS reads the embedded files by name.
type FS struct{}

func (FS) ReadFile(name string) ([]byte, error) { return files.ReadFile(name) }
