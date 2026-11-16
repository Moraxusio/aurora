package devtools

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"aurora3/internal/devprocess"
	"aurora3/internal/paths"
	"aurora3/internal/service"
	"aurora3/internal/wire"
)

func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ e *Env }

func (svc) ID() string                         { return "devtools" }
func (svc) Dependencies() []service.Dependency { return nil }
func (s svc) Operations() []service.Operation {
	return []service.Operation{
		{Name: "devtools.config", Handle: s.e.configuration},
		{Name: "devtools.configure", Handle: s.e.configure},
		{Name: "lsp.start", Stream: s.e.languageServer},
		{Name: "dap.start", Stream: s.e.debugAdapter},
		{Name: "task.run", Stream: s.e.runTask},
	}
}

// Both LSP and DAP use Content-Length envelopes. Bound headers and payloads
// before allocation, preserving raw UTF-8 JSON across the Aurora stream.
func readMessage(r *bufio.Reader) ([]byte, error) {
	length, headerBytes := -1, 0
	for {
		line, err := r.ReadSlice('\n')
		if err != nil {
			return nil, err
		}
		headerBytes += len(line)
		if headerBytes > 8192 {
			return nil, errors.New("protocol headers exceed 8 KiB")
		}
		if string(line) == "\r\n" || string(line) == "\n" {
			break
		}
		key, value, ok := strings.Cut(strings.TrimSpace(string(line)), ":")
		if !ok {
			return nil, errors.New("malformed protocol header")
		}
		if strings.EqualFold(key, "Content-Length") {
			if length != -1 {
				return nil, errors.New("duplicate Content-Length")
			}
			length, err = strconv.Atoi(strings.TrimSpace(value))
			if err != nil || length <= 0 || length >= wire.MaxFrame {
				return nil, wire.ErrFrameTooLarge
			}
		}
	}
	if length < 0 {
		return nil, errors.New("Content-Length missing")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	if !json.Valid(payload) {
		return nil, errors.New("invalid protocol JSON")
	}
	return payload, nil
}

func writeMessage(w io.Writer, payload []byte) error {
	if len(payload) == 0 || len(payload) >= wire.MaxFrame || !json.Valid(payload) {
		return wire.ErrFrameTooLarge
	}
	if _, err := fmt.Fprintf(w, "Content-Length: %d\r\n\r\n", len(payload)); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

type streamWriter struct {
	mu   sync.Mutex
	conn net.Conn
}

func (w *streamWriter) frame(typ byte, data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	_ = w.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
	return wire.WriteFrame(w.conn, typ, data)
}
func (w *streamWriter) event(value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return w.frame(wire.TypeJSON, data)
}

func readTextChunks(input io.Reader, emit func(string) error) error {
	r := bufio.NewReaderSize(input, 4096)
	var text strings.Builder
	for {
		value, _, err := r.ReadRune()
		if err != nil {
			if text.Len() > 0 {
				if e := emit(text.String()); e != nil {
					return e
				}
			}
			return err
		}
		text.WriteRune(value)
		if text.Len() >= 4096 || r.Buffered() == 0 {
			if err := emit(text.String()); err != nil {
				return err
			}
			text.Reset()
		}
	}
}

func (e *Env) languageServer(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	return e.protocol(ctx, st, raw, false)
}
func (e *Env) debugAdapter(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	return e.protocol(ctx, st, raw, true)
}
func (e *Env) protocol(ctx context.Context, st net.Conn, raw json.RawMessage, dap bool) error {
	a, err := decodeScope(raw)
	if err != nil {
		return err
	}
	rootPath, work, err := e.scope(a)
	if err != nil {
		return err
	}
	cfg, state, err := readConfig(work)
	if err != nil {
		return err
	}
	if a.IfMatch != "" && a.IfMatch != configTag(state) {
		return wire.Errf(wire.CodeConflict, "开发配置已变化，请重新启动开发工具")
	}
	var program *Program
	var settings any
	if dap {
		for _, d := range cfg.Debug {
			if d.ID == a.ID {
				p := d.Program
				program, settings = &p, d
				break
			}
		}
	} else {
		for _, s := range cfg.LanguageServers {
			if s.ID == a.ID {
				p := s.Program
				program, settings = &p, s
				break
			}
		}
	}
	if program == nil {
		return wire.Errf(wire.CodeNotFound, "开发工具未配置: %s", a.ID)
	}
	cwd := work
	if program.Cwd != "" {
		cwd, err = paths.Resolve(work, program.Cwd)
		if err != nil {
			return err
		}
	}
	release, err := e.acquire()
	if err != nil {
		return err
	}
	defer release()
	p, err := devprocess.Start(program.Command, cwd, e.environment(program.Env))
	if err != nil {
		return wire.Errf(wire.CodeUnavailable, "启动 %s 失败: %v", a.ID, err)
	}
	defer p.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { p.Kill(); _ = st.Close() })
	defer stop()
	// Once acknowledged, this operation owns the stream and reports errors as
	// events. Startup failures above remain ordinary Aurora error responses.
	defer st.Close()
	w := &streamWriter{conn: st}
	if err := w.event(wire.OKResponse(map[string]any{"rootUri": fileURI(rootPath),
		"workspaceUri": fileURI(work), "configuration": settings})); err != nil {
		return err
	}
	if e.Audit != nil {
		e.Audit.Write("devtools.start", map[string]any{"root": a.Root, "path": a.Path, "id": a.ID, "debug": dap})
	}
	var readers sync.WaitGroup
	readers.Add(2)
	go func() {
		defer readers.Done()
		r := bufio.NewReaderSize(p.Stdout, 8192)
		for {
			payload, err := readMessage(r)
			if err != nil {
				if !errors.Is(err, io.EOF) && ctx.Err() == nil {
					_ = w.event(map[string]any{"type": "error", "message": err.Error()})
					p.Kill()
				}
				return
			}
			if w.frame(wire.TypeData, payload) != nil {
				cancel()
				return
			}
		}
	}()
	go func() {
		defer readers.Done()
		_ = readTextChunks(p.Stderr, func(text string) error {
			err := w.event(map[string]any{"type": "stderr", "text": text})
			if err != nil {
				cancel()
			}
			return err
		})
	}()
	inputDone := make(chan struct{})
	go func() {
		defer close(inputDone)
		for {
			typ, payload, err := wire.ReadFrame(st)
			if err != nil || typ == wire.TypeEnd {
				cancel()
				return
			}
			if typ != wire.TypeData {
				cancel()
				return
			}
			if err := writeMessage(p.Stdin, payload); err != nil {
				cancel()
				return
			}
		}
	}()
	exit := p.Wait()
	readers.Wait()
	if ctx.Err() == nil {
		_ = w.event(map[string]any{"type": "exit", "code": devprocess.ExitCode(exit)})
	}
	cancel()
	<-inputDone
	return nil
}
