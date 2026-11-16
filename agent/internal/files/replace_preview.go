package files

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"aurora3/internal/wire"
)

const maxReplacements = 20000

type replacementPart struct {
	text  string
	group int // -1 for literal text
}

var replacementRef = regexp.MustCompile(`\$(\$|\{[A-Za-z_0-9]+\}|[A-Za-z_0-9]+)`)

func replacementParts(value string, re *regexp.Regexp, regex bool) ([]replacementPart, error) {
	if len(value) > 16<<10 {
		return nil, errors.New("替换内容超过 16 KiB")
	}
	if !regex {
		return []replacementPart{{text: value, group: -1}}, nil
	}
	var parts []replacementPart
	offset := 0
	for _, loc := range replacementRef.FindAllStringIndex(value, -1) {
		if loc[0] > offset {
			parts = append(parts, replacementPart{text: value[offset:loc[0]], group: -1})
		}
		name := strings.Trim(value[loc[0]+1:loc[1]], "{}")
		if name == "$" {
			parts = append(parts, replacementPart{text: "$", group: -1})
		} else {
			group, err := strconv.Atoi(name)
			if err != nil {
				group = re.SubexpIndex(name)
			}
			if group < 0 || group > re.NumSubexp() {
				return nil, errors.New("替换内容引用了不存在的捕获组：" + name)
			}
			parts = append(parts, replacementPart{group: group})
		}
		offset = loc[1]
	}
	if offset < len(value) {
		parts = append(parts, replacementPart{text: value[offset:], group: -1})
	}
	return parts, nil
}

// The search UI matches one line at a time with CR excluded. Use exactly that
// matcher and retain each original separator. Output, matches and captures all
// have hard budgets; replacement expansion checks size before allocating.
func replaceTextPreview(ctx context.Context, text []byte, re *regexp.Regexp, parts []replacementPart) ([]byte, int, error) {
	if len(text) > maxEditorBytes || !utf8.Valid(text) || bytes.IndexByte(text, 0) >= 0 {
		return nil, 0, errors.New("替换输入须为不超过 4 MiB 的 UTF-8 文本")
	}
	if re.NumSubexp() > 32 {
		return nil, 0, errors.New("替换表达式最多包含 32 个捕获组")
	}
	out := make([]byte, 0, len(text))
	appendText := func(b []byte) error {
		if len(b) > maxEditorBytes-len(out) {
			return errors.New("替换结果超过 4 MiB")
		}
		out = append(out, b...)
		return nil
	}
	count := 0
	for len(text) > 0 {
		if err := ctx.Err(); err != nil {
			return nil, 0, err
		}
		end := bytes.IndexByte(text, '\n')
		if end < 0 {
			end = len(text)
		}
		next := min(end+1, len(text))
		bodyEnd := end
		if bodyEnd > 0 && text[bodyEnd-1] == '\r' {
			bodyEnd--
		}
		line := text[:bodyEnd]
		matches := re.FindAllSubmatchIndex(line, maxReplacements-count+1)
		if len(matches) > maxReplacements-count {
			return nil, 0, errors.New("替换次数超过 20000 次，请缩小范围")
		}
		pos := 0
		for _, m := range matches {
			if err := ctx.Err(); err != nil {
				return nil, 0, err
			}
			if err := appendText(line[pos:m[0]]); err != nil {
				return nil, 0, err
			}
			for _, part := range parts {
				var value []byte
				if part.group < 0 {
					value = []byte(part.text)
				} else if m[2*part.group] >= 0 {
					value = line[m[2*part.group]:m[2*part.group+1]]
				}
				if err := appendText(value); err != nil {
					return nil, 0, err
				}
			}
			pos = m[1]
			count++
		}
		if err := appendText(line[pos:]); err != nil {
			return nil, 0, err
		}
		if err := appendText(text[bodyEnd:next]); err != nil {
			return nil, 0, err
		}
		text = text[next:]
	}
	return out, count, nil
}

// A pure preview over a client snapshot. It never touches the filesystem. The
// later fs.commit checks every disk version after all input has been received.
func (e *Env) fsReplacePreview(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var args struct {
		Query       string `json:"query"`
		Replacement string `json:"replacement"`
		Regex       bool   `json:"regex"`
		Case        bool   `json:"case"`
		Word        bool   `json:"word"`
		Size        int    `json:"size"`
	}
	if err := decode(raw, &args); err != nil {
		return err
	}
	if args.Query == "" || len(args.Query) > 1000 || args.Size < 0 || args.Size > maxEditorBytes {
		return wire.Errf(wire.CodeBadRequest, "替换查询或输入大小无效")
	}
	re, err := buildMatcher(args.Query, args.Regex, args.Case, args.Word)
	if err != nil {
		return wire.Errf(wire.CodeBadRequest, "表达式无效：%v", err)
	}
	parts, err := replacementParts(args.Replacement, re, args.Regex)
	if err != nil {
		return wire.Errf(wire.CodeBadRequest, "%v", err)
	}
	release, err := e.acquireTextOperation()
	if err != nil {
		return err
	}
	defer release()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = st.Close() })
	defer stop()
	_ = st.SetDeadline(time.Now().Add(30 * time.Second))
	if err := wire.WriteJSON(st, wire.OKResponse(map[string]any{"ready": true})); err != nil {
		return err
	}
	text := make([]byte, 0, args.Size)
	for len(text) < args.Size {
		typ, data, err := wire.ReadFrame(st)
		if err != nil {
			return err
		}
		if typ != wire.TypeData || len(data) == 0 || len(data) > args.Size-len(text) {
			return wire.Errf(wire.CodeBadRequest, "替换输入帧长度无效")
		}
		text = append(text, data...)
	}
	typ, _, err := wire.ReadFrame(st)
	if err != nil {
		return err
	}
	if typ != wire.TypeEnd {
		return wire.Errf(wire.CodeBadRequest, "缺少替换输入结束帧")
	}
	inputDone := make(chan struct{})
	go func() { defer close(inputDone); _, _, _ = wire.ReadFrame(st); cancel() }()
	defer func() { st.Close(); <-inputDone }()
	out, count, err := replaceTextPreview(ctx, text, re, parts)
	if err != nil {
		return wire.WriteJSON(st, wire.ErrResponse(wire.Errf(wire.CodeBadRequest, "%v", err)))
	}
	return sendTextFrames(ctx, st, map[string]any{"replacements": count}, out)
}
