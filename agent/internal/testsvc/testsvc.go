// Package testsvc is a service used only by tests and benchmarks: it gives a
// client unary and stream operations with known answers, so the client's
// protocol code can be checked against the real entry (TLS, Hello, yamux).
// It is never part of aurora3-agent's service list.
package testsvc

import (
	"context"
	"encoding/json"
	"net"

	"aurora3/internal/service"
	"aurora3/internal/wire"
)

// ID is the service name; tests switch it with agent.service.
const ID = "test"

type svc struct{}

// Service returns the test service.
func Service() service.Service { return svc{} }

func (svc) ID() string                         { return ID }
func (svc) Dependencies() []service.Dependency { return nil }

func (svc) Operations() []service.Operation {
	return []service.Operation{
		{Name: "test.echo", Handle: echo},
		{Name: "test.pipe", Stream: pipe},
		{Name: "test.source", Stream: source},
		{Name: "test.sink", Stream: sink},
		{Name: "test.hold", Stream: hold},
	}
}

func decode(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return wire.Errf(wire.CodeBadRequest, "参数格式错误：%v", err)
	}
	return nil
}

// echo returns its text; fail=true returns a conflict error.
func echo(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		Text string `json:"text"`
		Fail bool   `json:"fail"`
	}
	if err := decode(raw, &a); err != nil {
		return nil, err
	}
	if a.Fail {
		return nil, wire.Errf(wire.CodeConflict, "冲突：%s", a.Text)
	}
	return map[string]any{"text": a.Text}, nil
}

// pipe answers OK, then sends every frame back until 'E', which it answers
// with 'E' (the shape of a terminal stream).
func pipe(_ context.Context, st net.Conn, _ json.RawMessage) error {
	if err := wire.WriteJSON(st, wire.OKResponse(nil)); err != nil {
		return err
	}
	for {
		typ, p, err := wire.ReadFrame(st)
		if err != nil {
			return err
		}
		if typ == wire.TypeEnd {
			return wire.WriteFrame(st, wire.TypeEnd, nil)
		}
		if err := wire.WriteFrame(st, typ, p); err != nil {
			return err
		}
	}
}

// Pattern is the byte at absolute offset i of every test transfer.
func Pattern(i int64) byte { return byte(i % 251) }

// source answers OK with the size, then sends bytes of Pattern in 'D' frames
// of chunk bytes, then 'E' (the shape of fs.download).
func source(_ context.Context, st net.Conn, raw json.RawMessage) error {
	var a struct {
		Bytes int64 `json:"bytes"`
		Chunk int   `json:"chunk"`
	}
	if err := decode(raw, &a); err != nil {
		return err
	}
	if a.Chunk <= 0 || a.Chunk >= wire.MaxFrame {
		a.Chunk = wire.DataChunk
	}
	if err := wire.WriteJSON(st, wire.OKResponse(map[string]any{"bytes": a.Bytes})); err != nil {
		return err
	}
	buf := make([]byte, a.Chunk)
	for off := int64(0); off < a.Bytes; {
		n := int64(len(buf))
		if a.Bytes-off < n {
			n = a.Bytes - off
		}
		for i := int64(0); i < n; i++ {
			buf[i] = Pattern(off + i)
		}
		if err := wire.WriteFrame(st, wire.TypeData, buf[:n]); err != nil {
			return err
		}
		off += n
	}
	return wire.WriteFrame(st, wire.TypeEnd, nil)
}

// sink reads 'D' frames until 'E', checks every byte against Pattern, and
// answers with the count (the shape of fs.upload: the Response comes last).
func sink(_ context.Context, st net.Conn, _ json.RawMessage) error {
	var n int64
	ok := true
	for {
		typ, p, err := wire.ReadFrame(st)
		if err != nil {
			return err
		}
		if typ == wire.TypeEnd {
			break
		}
		if typ != wire.TypeData {
			return wire.Errf(wire.CodeBadRequest, "unexpected frame %q", typ)
		}
		for i, b := range p {
			if b != Pattern(n+int64(i)) {
				ok = false
			}
		}
		n += int64(len(p))
	}
	return wire.WriteJSON(st, wire.OKResponse(map[string]any{"bytes": n, "ok": ok}))
}

// hold answers OK and then waits until the client ends the stream.
func hold(ctx context.Context, st net.Conn, _ json.RawMessage) error {
	if err := wire.WriteJSON(st, wire.OKResponse(nil)); err != nil {
		return err
	}
	stop := context.AfterFunc(ctx, func() { _ = st.Close() })
	defer stop()
	buf := make([]byte, 4096)
	for {
		if _, err := st.Read(buf); err != nil {
			return nil
		}
	}
}
