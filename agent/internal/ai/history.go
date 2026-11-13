//go:build linux || windows

package ai

import (
	"context"
	"encoding/json"
	"net"
	"time"

	"aurora3/internal/wire"
)

// History uses bounded data frames: a single message (including diffs/tool output)
// can itself exceed MaxFrame. Keep the normal wire frame limit unchanged.
func (s svc) opHistory(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	res, err := s.opGet(ctx, raw)
	if err != nil {
		return err
	}
	b, err := json.Marshal(res)
	if err != nil {
		return err
	}
	if len(b) > 64<<20 {
		return wire.Errf(wire.CodeBadRequest, "会话历史超过 64 MiB，请导出或拆分会话")
	}
	_ = st.SetWriteDeadline(time.Now().Add(60 * time.Second))
	if err := wire.WriteJSON(st, wire.OKResponse(map[string]any{"size": len(b)})); err != nil {
		return err
	}
	for len(b) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := min(len(b), wire.DataChunk)
		if err := wire.WriteFrame(st, wire.TypeData, b[:n]); err != nil {
			return err
		}
		b = b[n:]
	}
	return wire.WriteFrame(st, wire.TypeEnd, nil)
}
