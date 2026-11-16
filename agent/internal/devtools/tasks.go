package devtools

import (
	"context"
	"encoding/json"
	"net"
	"sync"
	"time"

	"aurora3/internal/devprocess"
	"aurora3/internal/paths"
	"aurora3/internal/wire"
)

func (e *Env) runTask(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	a, err := decodeScope(raw)
	if err != nil {
		return err
	}
	_, work, err := e.scope(a)
	if err != nil {
		return err
	}
	cfg, state, err := readConfig(work)
	if err != nil {
		return err
	}
	if a.IfMatch != "" && a.IfMatch != configTag(state) {
		return wire.Errf(wire.CodeConflict, "开发配置已变化，请重新选择任务")
	}
	tasks := map[string]Task{}
	for _, t := range cfg.Tasks {
		tasks[t.ID] = t
	}
	if _, ok := tasks[a.ID]; !ok {
		return wire.Errf(wire.CodeNotFound, "任务未配置: %s", a.ID)
	}
	release, err := e.acquire()
	if err != nil {
		return err
	}
	defer release()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = st.Close() })
	defer stop()
	defer st.Close()
	w := &streamWriter{conn: st}
	if err := w.event(wire.OKResponse(map[string]any{"id": a.ID, "workspaceUri": fileURI(work)})); err != nil {
		return err
	}
	inputDone := make(chan struct{})
	go func() { defer close(inputDone); _, _, _ = wire.ReadFrame(st); cancel() }()
	defer func() { cancel(); st.Close(); <-inputDone }()
	done := map[string]bool{}
	var run func(string) int
	run = func(id string) int {
		if done[id] {
			return 0
		}
		if ctx.Err() != nil {
			return -1
		}
		task := tasks[id]
		for _, dep := range task.DependsOn {
			if code := run(dep); code != 0 {
				return code
			}
		}
		done[id] = true
		cwd := work
		if task.Cwd != "" {
			cwd, err = paths.Resolve(work, task.Cwd)
			if err != nil {
				_ = w.event(map[string]any{"type": "error", "message": err.Error()})
				return -1
			}
		}
		timeout := task.TimeoutSeconds
		if timeout == 0 {
			timeout = 600
		}
		runCtx, runCancel := context.WithTimeout(ctx, time.Duration(timeout)*time.Second)
		defer runCancel()
		p, err := devprocess.Start(task.Command, cwd, e.environment(task.Env))
		if err != nil {
			_ = w.event(map[string]any{"type": "error", "task": id, "message": err.Error()})
			return -1
		}
		defer p.Close()
		stop := context.AfterFunc(runCtx, p.Kill)
		defer stop()
		start := time.Now()
		if w.event(map[string]any{"type": "started", "task": id, "configuration": task, "cwd": fileURI(cwd), "problemMatching": "agent-re2"}) != nil {
			cancel()
			return -1
		}
		if e.Audit != nil {
			e.Audit.Write("task.run", map[string]any{"root": a.Root, "path": a.Path, "id": id})
		}
		var output sync.WaitGroup
		output.Add(2)
		for _, stream := range []struct {
			name string
			read interface{ Read([]byte) (int, error) }
		}{{"stdout", p.Stdout}, {"stderr", p.Stderr}} {
			go func() {
				defer output.Done()
				re, _ := problemMatcher(task.ProblemPattern) // validated configuration
				parser := &taskProblemParser{re: re, goJSON: task.TestFormat == "go-json", emit: func(problem map[string]any) error {
					return w.event(map[string]any{"type": "problem", "task": id, "problem": problem})
				}}
				_ = readTextChunks(stream.read, func(text string) error {
					err := w.event(map[string]any{"type": "output", "task": id, "stream": stream.name, "text": text})
					if err == nil {
						err = parser.append(text)
					}
					if err != nil {
						cancel()
					}
					return err
				})
				if err := parser.finish(); err != nil {
					cancel()
				}
			}()
		}
		exit := p.Wait()
		output.Wait()
		code := devprocess.ExitCode(exit)
		if runCtx.Err() != nil && code == 0 {
			code = -1
		}
		_ = w.event(map[string]any{"type": "finished", "task": id, "code": code,
			"cancelled": runCtx.Err() != nil, "elapsedMs": time.Since(start).Milliseconds()})
		return code
	}
	code := run(a.ID)
	if ctx.Err() == nil {
		_ = w.event(map[string]any{"type": "complete", "code": code})
	}
	return nil
}
