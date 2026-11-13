package ai

import (
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

func materializeAttachments(messages []Message, load func(Part) ([]byte, error)) ([]Message, error) {
	out := append([]Message(nil), messages...)
	for i, m := range out {
		out[i].Parts = append([]Part(nil), m.Parts...)
		for j, p := range m.Parts {
			if p.AttachmentID == "" {
				continue
			}
			if load == nil {
				return nil, errors.New("当前请求不能读取附件，请升级 agent")
			}
			b, err := load(p)
			if err != nil {
				return nil, err
			}
			if strings.HasPrefix(p.Mime, "text/") {
				p.Type = "text"
				p.Text = fmt.Sprintf("<context filename=%q>\n%s\n</context>", p.Filename, string(b))
			} else {
				p.DataURL = "data:" + p.Mime + ";base64," + base64.StdEncoding.EncodeToString(b)
			}
			out[i].Parts[j] = p
		}
	}
	return out, nil
}
