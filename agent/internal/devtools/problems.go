package devtools

import (
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
)

const problemLineMax = 16 << 10
const defaultProblemPattern = `^\s*(?P<file>.+?):(?P<line>\d+)(?::(?P<column>\d+))?:\s*(?P<message>.*)$`

func problemMatcher(pattern string) (*regexp.Regexp, error) {
	if pattern == "" {
		pattern = defaultProblemPattern
	}
	if len(pattern) > 4096 {
		return nil, errors.New("问题匹配器超过 4096 字节")
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return nil, err
	}
	if re.NumSubexp() > 32 || re.SubexpIndex("file") < 0 || re.SubexpIndex("line") < 0 {
		return nil, errors.New("问题匹配器须包含 file、line 命名组，最多 32 个捕获组")
	}
	return re, nil
}

type taskProblemParser struct {
	re        *regexp.Regexp
	goJSON    bool
	pending   string
	oversized bool
	count     int
	emit      func(map[string]any) error
}

func (p *taskProblemParser) append(text string) error {
	for len(text) > 0 {
		end := strings.IndexByte(text, '\n')
		if end < 0 {
			end = len(text)
		}
		if !p.oversized {
			if len(p.pending)+end > problemLineMax {
				p.oversized = true
				p.pending = ""
			} else {
				p.pending += text[:end]
			}
		}
		if end == len(text) {
			break
		}
		if err := p.finish(); err != nil {
			return err
		}
		text = text[end+1:]
	}
	return nil
}
func (p *taskProblemParser) finish() error {
	line, skip := strings.TrimSuffix(p.pending, "\r"), p.oversized
	p.pending, p.oversized = "", false
	if skip || p.count >= 500 || line == "" {
		return nil
	}
	if p.goJSON {
		var event struct{ Output string }
		if json.Unmarshal([]byte(line), &event) == nil && event.Output != "" {
			for _, output := range strings.Split(event.Output, "\n") {
				if err := p.match(output); err != nil {
					return err
				}
			}
			return nil
		}
	}
	return p.match(line)
}
func (p *taskProblemParser) match(line string) error {
	if p.count >= 500 {
		return nil
	}
	m := p.re.FindStringSubmatch(line)
	if m == nil {
		return nil
	}
	field := func(name string) string {
		i := p.re.SubexpIndex(name)
		if i < 0 {
			return ""
		}
		return m[i]
	}
	file := field("file")
	number, _ := strconv.Atoi(field("line"))
	column, _ := strconv.Atoi(field("column"))
	if file == "" || number < 1 || number > 100000000 {
		return nil
	}
	column = min(max(column, 1), 1000000)
	message, severity := field("message"), field("severity")
	if message == "" {
		message = line
	}
	if severity == "" {
		severity = "error"
		if strings.Contains(strings.ToLower(message), "warning") {
			severity = "warning"
		}
	}
	p.count++
	return p.emit(map[string]any{"file": file, "line": number, "column": column, "message": message, "severity": severity})
}
