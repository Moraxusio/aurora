package files

// Text side of search (no OS calls; tested on any platform).

import (
	"aurora3/internal/paths"
	"errors"
	"path"
	"regexp"
	"sort"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// skipDirs are never descended into by a folder walk (git's own list of
// files is used inside repositories instead).
var skipDirs = paths.SkipDirs

// globSet matches paths against comma-separated globs. A glob without a
// slash matches the file name at any depth ("*.py"); with one it matches the
// path from the search folder ("src/**/*.ts"). "**" spans folders, "{a,b}"
// alternates.
type globSet []*regexp.Regexp

func parseGlobs(s string) globSet {
	var out globSet
	for _, g := range splitGlobs(s) {
		g = strings.TrimPrefix(strings.TrimSpace(g), "./")
		if g == "" {
			continue
		}
		if strings.HasSuffix(g, "/") {
			g += "**"
		}
		anchored := strings.Contains(strings.TrimSuffix(g, "/**"), "/")
		re := globRegexp(g)
		if !anchored {
			re = "(^|.*/)" + re
		}
		if r, err := regexp.Compile("^" + re + "(/.*)?$"); err == nil {
			out = append(out, r)
		}
	}
	return out
}

// splitGlobs splits on commas outside braces.
func splitGlobs(s string) []string {
	var out []string
	depth, start := 0, 0
	for i, c := range s {
		switch c {
		case '{':
			depth++
		case '}':
			if depth > 0 {
				depth--
			}
		case ',':
			if depth == 0 {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	return append(out, s[start:])
}

func globRegexp(g string) string {
	var b strings.Builder
	brace := 0
	for i := 0; i < len(g); i++ {
		c := g[i]
		switch {
		case c == '*' && i+1 < len(g) && g[i+1] == '*':
			i++
			if i+1 < len(g) && g[i+1] == '/' {
				i++
				b.WriteString("(.*/)?")
			} else {
				b.WriteString(".*")
			}
		case c == '*':
			b.WriteString("[^/]*")
		case c == '?':
			b.WriteString("[^/]")
		case c == '{':
			brace++
			b.WriteString("(")
		case c == '}' && brace > 0:
			brace--
			b.WriteString(")")
		case c == ',' && brace > 0:
			b.WriteString("|")
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	return b.String()
}

func (g globSet) match(rel string) bool {
	for _, r := range g {
		if r.MatchString(rel) {
			return true
		}
	}
	return false
}

var errEmptyMatch = errors.New("这个表达式会匹配空字符串")

// buildMatcher turns the query options into one regexp.
func buildMatcher(query string, isRegex, caseSensitive, word bool) (*regexp.Regexp, error) {
	q := query
	if !isRegex {
		q = regexp.QuoteMeta(q)
	}
	if word {
		q = "\\b(?:" + q + ")\\b"
	}
	if !caseSensitive {
		q = "(?i)" + q
	}
	re, err := regexp.Compile(q)
	if err != nil {
		return nil, err
	}
	if re.MatchString("") {
		return nil, errEmptyMatch
	}
	return re, nil
}

type lineMatch struct {
	Line   int      `json:"line"`   // 1-based
	Col    int      `json:"col"`    // 1-based, UTF-16 units (what the editor counts)
	Text   string   `json:"text"`   // the line, or a window of a long one
	Ranges [][2]int `json:"ranges"` // matches within Text, UTF-16 units
}

const maxLineShown = 400

// matchLines finds the matching lines of content (at most limit).
func matchLines(content []byte, re *regexp.Regexp, limit int) []lineMatch {
	var out []lineMatch
	n := 0
	for len(content) > 0 && len(out) < limit {
		n++
		var line []byte
		if i := indexByte(content, '\n'); i < 0 {
			line, content = content, nil
		} else {
			line, content = content[:i], content[i+1:]
		}
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		locs := re.FindAllIndex(line, 20)
		if len(locs) == 0 {
			continue
		}
		out = append(out, shownLine(line, locs, n))
	}
	return out
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

// shownLine cuts a long line to a window around its first match.
func shownLine(line []byte, locs [][]int, n int) lineMatch {
	from, to := 0, len(line)
	if len(line) > maxLineShown {
		from = max(locs[0][0]-60, 0)
		for from > 0 && !utf8.RuneStart(line[from]) {
			from--
		}
		to = min(from+maxLineShown, len(line))
		for to < len(line) && !utf8.RuneStart(line[to]) {
			to++
		}
	}
	text := strings.ToValidUTF8(string(line[from:to]), "\uFFFD")
	m := lineMatch{Line: n, Col: u16len(line[:locs[0][0]]) + 1, Text: text, Ranges: [][2]int{}}
	for _, l := range locs {
		if l[0] < from || l[1] > to {
			continue
		}
		s := u16len(line[from:l[0]])
		m.Ranges = append(m.Ranges, [2]int{s, s + u16len(line[l[0]:l[1]])})
	}
	return m
}

func u16len(b []byte) int {
	n := 0
	for _, r := range string(b) {
		n += len(utf16.Encode([]rune{r}))
	}
	return n
}

// fuzzyScore ranks a path for quick open: every query character in order,
// with bonuses in the file name, at word starts and for runs. -1: no match.
func fuzzyScore(p, q string) int {
	if q == "" {
		return 0
	}
	lp, lq := strings.ToLower(p), strings.ToLower(strings.ReplaceAll(q, " ", ""))
	base := strings.LastIndexByte(lp, '/') + 1
	depth := strings.Count(lp, "/")
	// the whole query inside the file name wins
	if i := strings.Index(lp[base:], lq); i >= 0 {
		name := lp[base:]
		s := 3000 - i*4 - (len(name) - len(lq)) - depth*5
		if i == 0 || (i == 1 && name[0] == '.') {
			s += 200 // at the start of the name (".bashrc" for "bashrc" too)
		}
		if stem := strings.TrimPrefix(name, "."); stem == lq || strings.TrimSuffix(stem, path.Ext(stem)) == lq {
			s += 300 // the name itself
		}
		return s
	}
	if i := strings.Index(lp, lq); i >= 0 {
		return 2000 - len(lp)
	}
	rs, qs := []rune(lp), []rune(lq)
	baseRune := len([]rune(lp[:base]))
	score, j, run, last := 0, 0, 0, -2
	for i := 0; i < len(rs) && j < len(qs); i++ {
		if rs[i] != qs[j] {
			continue
		}
		s := 1
		if i == last+1 {
			run++
			s += run * 3
		} else {
			run = 0
		}
		if i == 0 || rs[i-1] == '/' || rs[i-1] == '_' || rs[i-1] == '-' || rs[i-1] == '.' {
			s += 6
		}
		if i >= baseRune {
			s += 4
		}
		score += s
		last = i
		j++
	}
	if j < len(qs) {
		return -1
	}
	return max(score*10-len(rs), 0)
}

type found struct {
	Path  string
	score int
}

// rankFiles returns the best max paths for q.
func rankFiles(files []string, q string, max int) []found {
	var out []found
	for _, f := range files {
		if s := fuzzyScore(f, q); s >= 0 {
			out = append(out, found{Path: f, score: s})
		}
	}
	sort.SliceStable(out, func(a, b int) bool {
		if out[a].score != out[b].score {
			return out[a].score > out[b].score
		}
		return out[a].Path < out[b].Path
	})
	if len(out) > max {
		out = out[:max]
	}
	return out
}

// relJoin joins the search folder (root-relative) and a path below it.
func relJoin(dir, rel string) string { return path.Join("/", dir, rel) }

var logNameRe = regexp.MustCompile(`(^|[._-])logs?([._-]|$)|.log.d+$`)

// logName: a file name that says it is a log (see logLike in the page).
func logName(p string) bool {
	name := strings.ToLower(path.Base(p))
	switch path.Ext(name) {
	case ".log", ".out", ".err", ".stdout", ".stderr":
		return true
	}
	return logNameRe.MatchString(name)
}