// Package wire is the single protocol shared by Aurora's client, agent and relay.
//
// Transport: TLS 1.3 with SHA-256 certificate pinning, one hello exchange, then
// a yamux session. Every operation runs on its own yamux stream:
//
//	client -> server  'J' Request{op,args}
//	unary:            'J' Response
//	upload:           client 'D'... 'E', server 'J' Response
//	download:         server 'J' Response(meta), 'D'..., 'E'
//	terminal:         server 'J' Response, then 'D' both ways, 'J' control frames
//
// Frames are a 4-byte big-endian length, a 1-byte type and the payload.
package wire

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const (
	MaxFrame = 1 << 20

	TypeJSON byte = 'J'
	TypeData byte = 'D'
	TypeEnd  byte = 'E'

	// DataChunk is the payload size used for bulk transfers.
	DataChunk = 256 * 1024
)

var ErrFrameTooLarge = errors.New("frame too large")

// WriteFrame writes one frame with a single Write call so concurrent writers
// guarded by a mutex never interleave partial frames.
func WriteFrame(w io.Writer, typ byte, payload []byte) error {
	if len(payload)+1 > MaxFrame {
		return ErrFrameTooLarge
	}
	buf := make([]byte, 5+len(payload))
	binary.BigEndian.PutUint32(buf, uint32(len(payload)+1))
	buf[4] = typ
	copy(buf[5:], payload)
	_, err := w.Write(buf)
	return err
}

func WriteJSON(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return WriteFrame(w, TypeJSON, b)
}

// ReadFrame reads one frame. The returned payload is owned by the caller.
func ReadFrame(r io.Reader) (byte, []byte, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n < 1 || n > MaxFrame {
		return 0, nil, fmt.Errorf("%w: %d", ErrFrameTooLarge, n)
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return 0, nil, err
	}
	return body[0], body[1:], nil
}

// ReadJSON reads a frame that must be JSON and decodes it into v.
func ReadJSON(r io.Reader, v any) error {
	typ, payload, err := ReadFrame(r)
	if err != nil {
		return err
	}
	if typ != TypeJSON {
		return fmt.Errorf("expected JSON frame, got %q", typ)
	}
	return json.Unmarshal(payload, v)
}
