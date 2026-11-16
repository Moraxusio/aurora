package files

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"time"
	"unicode/utf8"

	"aurora3/internal/wire"
)

const maxEditorBytes = 4 << 20
const maxTextWindow = 256 << 10

func (e *Env) acquireTextOperation() (func(), error) {
	e.textMu.Lock()
	defer e.textMu.Unlock()
	if e.textRunning >= 3 {
		return nil, wire.Errf(wire.CodeUnavailable, "文本传输已达到 3 个并发上限")
	}
	e.textRunning++
	return func() { e.textMu.Lock(); e.textRunning--; e.textMu.Unlock() }, nil
}

// Text is sent as bounded UTF-8 data frames, independent of JSON escaping and
// source encoding. Window mode is read-only UTF-8 and never loads the full file.
func (e *Env) fsText(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var opt struct {
		Encoding string `json:"encoding"`
		Window   bool   `json:"window"`
		Offset   int64  `json:"offset"`
		Length   int    `json:"length"`
		IfMatch  string `json:"if_match"`
	}
	if err := decode(raw, &opt); err != nil {
		return err
	}
	if opt.Offset < 0 || opt.Length < 0 {
		return wire.Errf(wire.CodeBadRequest, "文本窗口范围无效")
	}
	_, root, rel, err := e.fsPrep(raw)
	if err != nil {
		return err
	}
	defer root.Close()
	release, err := e.acquireTextOperation()
	if err != nil {
		return err
	}
	defer release()
	f, err := root.Open(rel)
	if err != nil {
		return fsErr(err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return fsErr(err)
	}
	if !info.Mode().IsRegular() {
		return wire.Errf(wire.CodeBadRequest, "不是普通文件")
	}
	if opt.IfMatch != "" && opt.IfMatch != etag(info) {
		return wire.Errf(wire.CodeConflict, "文件已变化，请重新加载文本窗口")
	}
	prefix := make([]byte, 4)
	n, _ := f.ReadAt(prefix, 0)
	name := detectTextEncoding(prefix[:n], opt.Encoding)
	if _, _, err := textEncoding(name); err != nil {
		return wire.Errf(wire.CodeBadRequest, "%v", err)
	}
	meta := map[string]any{"size": info.Size(), "etag": etag(info), "encoding": name, "modeBits": uint32(info.Mode().Perm())}
	var text []byte
	if !opt.Window && info.Size() > maxEditorBytes {
		meta["large"] = true
	} else {
		if opt.Window && name != "utf-8" && name != "utf-8-bom" {
			return wire.Errf(wire.CodeBadRequest, "字节窗口阅读支持 UTF-8；其它编码可完整打开不超过 4 MiB 的文件")
		}
		limit := int64(maxEditorBytes + 1)
		if opt.Window {
			if opt.Length == 0 {
				opt.Length = 64 << 10
			}
			if opt.Length < 16 || opt.Length > maxTextWindow {
				return wire.Errf(wire.CodeBadRequest, "文本窗口须在 16 字节与 256 KiB 之间")
			}
			limit = int64(opt.Length)
		}
		offset := min(opt.Offset, info.Size())
		if !opt.Window {
			offset = 0
		}
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return fsErr(err)
		}
		data, err := io.ReadAll(io.LimitReader(f, limit))
		if err != nil {
			return fsErr(err)
		}
		if !opt.Window && len(data) > maxEditorBytes {
			return wire.Errf(wire.CodeConflict, "文件已增长，请使用阅读模式")
		}
		if opt.Window {
			// An arbitrary byte jump may land inside a UTF-8 character.
			for len(data) > 0 && offset > 0 && !utf8.RuneStart(data[0]) {
				data = data[1:]
				offset++
			}
			if offset+int64(len(data)) < info.Size() {
				for cut := 0; cut < 4 && len(data) > 0 && !utf8.Valid(data); cut++ {
					data = data[:len(data)-1]
				}
			}
			meta["offset"], meta["nextOffset"] = offset, offset+int64(len(data))
			meta["eof"] = offset+int64(len(data)) >= info.Size()
			if offset > 0 && name == "utf-8-bom" {
				name = "utf-8"
			}
		}
		text, err = decodeText(data, name)
		if err != nil {
			meta["binary"], meta["message"] = true, err.Error()
			text = nil
		}
		if len(text) > 4*maxEditorBytes {
			return wire.Errf(wire.CodeBadRequest, "解码结果超过预算")
		}
		current, err := f.Stat()
		if err != nil {
			return fsErr(err)
		}
		target, err := root.Stat(rel)
		if err != nil {
			return fsErr(err)
		}
		if etag(current) != etag(info) || !os.SameFile(info, target) {
			return wire.Errf(wire.CodeConflict, "读取期间文件已变化")
		}
	}
	stop := context.AfterFunc(ctx, func() { _ = st.Close() })
	defer stop()
	return sendTextFrames(ctx, st, meta, text)
}

func sendTextFrames(ctx context.Context, st net.Conn, meta map[string]any, text []byte) error {
	meta["textBytes"] = len(text)
	_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if err := wire.WriteJSON(st, wire.OKResponse(meta)); err != nil {
		return err
	}
	for reader := bytes.NewReader(text); reader.Len() > 0; {
		if err := ctx.Err(); err != nil {
			return err
		}
		buffer := make([]byte, min(reader.Len(), wire.DataChunk))
		_, _ = io.ReadFull(reader, buffer)
		_ = st.SetWriteDeadline(time.Now().Add(30 * time.Second))
		if err := wire.WriteFrame(st, wire.TypeData, buffer); err != nil {
			return err
		}
	}
	return wire.WriteFrame(st, wire.TypeEnd, nil)
}
