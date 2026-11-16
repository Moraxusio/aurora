//go:build linux || windows

package files

import (
	"context"
	"encoding/json"
	"net"

	"aurora3/internal/wire"
)

// Unlike a unary call, the client leaves its send side open until completion.
// Closing/resetting that stream cancels walking, git listing and scan workers.
func (e *Env) fsSearchStream(ctx context.Context, st net.Conn, args json.RawMessage) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer st.Close()
	stop := context.AfterFunc(ctx, func() { _ = st.Close() })
	defer stop()
	go func() {
		_, _, _ = wire.ReadFrame(st)
		cancel()
	}()
	result, err := e.fsSearch(ctx, args)
	if err != nil {
		return wire.WriteJSON(st, wire.ErrResponse(err))
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return wire.WriteJSON(st, wire.OKResponse(result))
}
