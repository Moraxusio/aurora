//go:build !linux

package netfwd

import (
	"context"
	"encoding/json"

	"aurora3/internal/wire"
)

// net.ports reads /proc, so it exists on Linux only. net.dial is portable, which
// lets the test peer serve the net service on any platform.
func (e *Env) netPorts(context.Context, json.RawMessage) (any, error) {
	return nil, wire.Errf(wire.CodeUnsupported, "列出监听端口只支持 Linux")
}
