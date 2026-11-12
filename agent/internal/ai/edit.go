package ai

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

const utf8BOM = "\xef\xbb\xbf"

type editMatch struct {
	start int // byte offset in source (without BOM)
	end   int // byte offset in source (without BOM)
}

// EditResult is returned by ApplyEdit.
type EditResult struct {
	Content      string
	Replacements int
	Diff         FileDiff
}

// ApplyEdit ports OpenCode's 3-tier exact-edit engine (packages/core/src/tool/plugin/edit.ts):
// 1. Exact LF-view match
// 2. Typographic quote / dash / space normalized match
// 3. Per-line trailing-whitespace + normalized match
// Preserves UTF-8 BOM and existing CRLF/LF line endings (even in mixed-ending files via LCS alignment).
func ApplyEdit(fileLabel, rawSource, oldString, newString string, replaceAll bool) (EditResult, error) {
	if oldString == newString {
		return EditResult{}, errors.New("No changes to apply: oldString and newString are identical.")
	}
	if oldString == "" {
		return EditResult{}, errors.New("oldString must not be empty. Use write to create or overwrite a file.")
	}

	hasBOM := strings.HasPrefix(rawSource, utf8BOM)
	source := strings.TrimPrefix(rawSource, utf8BOM)

	endingsOnly := strings.ReplaceAll(oldString, "\r", "") == strings.ReplaceAll(newString, "\r", "")

	var matches []editMatch
	var replaceFn func(m editMatch) string

	if endingsOnly {
		matches = findByteOccurrences(source, oldString)
		replaceFn = func(editMatch) string { return newString }
	} else {
		matches, replaceFn = matchView(source, oldString, newString)
	}

	replacements := len(matches)
	if replacements == 0 {
		hint := missHint(source, oldString, newString)
		msg := fmt.Sprintf("Could not find oldString in %s. It must match exactly, including whitespace and indentation.", fileLabel)
		if hint != "" {
			msg += "\n\n" + hint
		}
		return EditResult{}, errors.New(msg)
	}
	if replacements > 1 && !replaceAll {
		return EditResult{}, fmt.Errorf("Found %d matches for oldString, but expected exactly one. Add more surrounding context to make oldString unique, or set replaceAll to true to replace every occurrence.", replacements)
	}

	targetMatches := matches
	if !replaceAll {
		targetMatches = matches[:1]
	}

	var b strings.Builder
	b.Grow(len(source) + len(newString))
	cursor := 0
	for _, m := range targetMatches {
		b.WriteString(source[cursor:m.start])
		b.WriteString(replaceFn(m))
		cursor = m.end
	}
	b.WriteString(source[cursor:])
	replaced := b.String()

	if replaced == source {
		if endingsOnly {
			return EditResult{}, fmt.Errorf("No changes to apply: %s already has those line endings.", fileLabel)
		}
		return EditResult{}, fmt.Errorf("No changes to apply: the edit leaves %s unchanged. Line endings follow the file; to change them, write \\r explicitly in oldString or newString.", fileLabel)
	}

	finalText := replaced
	if hasBOM {
		finalText = utf8BOM + replaced
	}
	diff := ComputeFileDiff(fileLabel, rawSource, finalText)
	return EditResult{
		Content:      finalText,
		Replacements: len(targetMatches),
		Diff:         diff,
	}, nil
}

func normalizeRune(r rune) rune {
	switch r {
	case '‘', '’', '‚', '‛':
		return '\''
	case '“', '”', '„', '‟':
		return '"'
	case '‐', '‑', '‒', '–', '—', '―', '−':
		return '-'
	case '\u00A0', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u202F', '\u205F', '\u3000':
		return ' '
	default:
		return r
	}
}

func normalizeForMatch(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		b.WriteRune(normalizeRune(r))
	}
	return b.String()
}

// normalizeWithByteMap normalizes s rune-by-rune and records a byte offset mapping
// from each byte start in normalized string back to its byte offset in s.
func normalizeWithByteMap(s string) (string, []int) {
	var b strings.Builder
	b.Grow(len(s))
	normToOrig := make([]int, 0, len(s)+1)
	for idx, r := range s {
		nr := normalizeRune(r)
		var buf [utf8.UTFMax]byte
		n := utf8.EncodeRune(buf[:], nr)
		for k := 0; k < n; k++ {
			normToOrig = append(normToOrig, idx)
		}
		b.Write(buf[:n])
	}
	normToOrig = append(normToOrig, len(s))
	return b.String(), normToOrig
}

func findByteOccurrences(content, search string) []editMatch {
	if search == "" {
		return nil
	}
	var out []editMatch
	offset := 0
	for {
		idx := strings.Index(content[offset:], search)
		if idx < 0 {
			break
		}
		start := offset + idx
		end := start + len(search)
		out = append(out, editMatch{start: start, end: end})
		offset = end
	}
	return out
}

type viewLine struct {
	start      int
	end        int
	text       string
	contentEnd int
	newline    bool
}

func findLineOccurrences(content, search string) []editMatch {
	trailingNewline := strings.HasSuffix(search, "\n")
	expected := strings.Split(search, "\n")
	if trailingNewline && len(expected) > 0 {
		expected = expected[:len(expected)-1]
	}
	if len(expected) == 0 {
		return nil
	}

	var lines []viewLine
	pos := 0
	for pos < len(content) {
		nl := strings.IndexByte(content[pos:], '\n')
		if nl < 0 {
			txt := content[pos:]
			ce := pos + len(txt)
			if strings.HasSuffix(txt, "\r") {
				ce--
			}
			lines = append(lines, viewLine{start: pos, end: len(content), text: txt, contentEnd: ce, newline: false})
			break
		}
		txt := content[pos : pos+nl]
		ce := pos + len(txt)
		if strings.HasSuffix(txt, "\r") {
			ce--
		}
		lines = append(lines, viewLine{start: pos, end: pos + nl + 1, text: txt, contentEnd: ce, newline: true})
		pos += nl + 1
	}

	var out []editMatch
	for i := 0; i+len(expected) <= len(lines); i++ {
		actual := lines[i : i+len(expected)]
		ok := true
		for j := 0; j < len(expected); j++ {
			a := normalizeForMatch(strings.TrimRight(actual[j].text, " \t\r"))
			e := normalizeForMatch(strings.TrimRight(expected[j], " \t\r"))
			if a != e {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		last := actual[len(actual)-1]
		if trailingNewline && !last.newline {
			continue
		}
		candEnd := last.contentEnd
		if trailingNewline {
			candEnd = last.end
		}
		cand := editMatch{start: actual[0].start, end: candEnd}
		overlap := false
		for _, prev := range out {
			if prev.end > cand.start && prev.start < cand.end {
				overlap = true
				break
			}
		}
		if !overlap {
			out = append(out, cand)
		}
	}
	return out
}

func dominantLineEnding(text, fallback string) string {
	crlfCount := strings.Count(text, "\r\n")
	lfCount := strings.Count(text, "\n") - crlfCount
	if crlfCount == lfCount {
		return fallback
	}
	if crlfCount > lfCount {
		return "\r\n"
	}
	return "\n"
}

func splitRegionLines(region string) ([]string, []string) {
	var lines []string
	var endings []string
	pos := 0
	for pos < len(region) {
		nl := strings.IndexByte(region[pos:], '\n')
		if nl < 0 {
			lines = append(lines, region[pos:])
			break
		}
		endIdx := pos + nl
		if endIdx > pos && region[endIdx-1] == '\r' {
			lines = append(lines, region[pos:endIdx-1])
			endings = append(endings, "\r\n")
		} else {
			lines = append(lines, region[pos:endIdx])
			endings = append(endings, "\n")
		}
		pos = endIdx + 1
	}
	if len(region) == 0 || strings.HasSuffix(region, "\n") {
		lines = append(lines, "")
	}
	return lines, endings
}

func alignLines(before, after []string) []int {
	width := len(after) + 1
	table := make([]int, (len(before)+1)*width)
	for i := len(before) - 1; i >= 0; i-- {
		for j := len(after) - 1; j >= 0; j-- {
			if before[i] == after[j] {
				table[i*width+j] = table[(i+1)*width+j+1] + 1
			} else {
				a := table[(i+1)*width+j]
				b := table[i*width+j+1]
				if a >= b {
					table[i*width+j] = a
				} else {
					table[i*width+j] = b
				}
			}
		}
	}
	result := make([]int, len(after))
	for k := range result {
		result[k] = -1
	}
	var gapBefore, gapAfter []int
	flush := func() {
		for k, j := range gapAfter {
			if k < len(gapBefore) {
				result[j] = gapBefore[k]
			}
		}
		gapBefore = gapBefore[:0]
		gapAfter = gapAfter[:0]
	}
	i, j := 0, 0
	for i < len(before) && j < len(after) {
		if before[i] == after[j] {
			flush()
			result[j] = i
			i++
			j++
			continue
		}
		if table[(i+1)*width+j] >= table[i*width+j+1] {
			gapBefore = append(gapBefore, i)
			i++
		} else {
			gapAfter = append(gapAfter, j)
			j++
		}
	}
	for i < len(before) {
		gapBefore = append(gapBefore, i)
		i++
	}
	for j < len(after) {
		gapAfter = append(gapAfter, j)
		j++
	}
	flush()
	return result
}

func withRegionEndings(region, replacement, fallback string) string {
	before, endings := splitRegionLines(region)
	after := strings.Split(replacement, "\n")
	beforeKeys := make([]string, len(before))
	for i, l := range before {
		beforeKeys[i] = normalizeForMatch(strings.TrimRight(l, " \t\r"))
	}
	afterKeys := make([]string, len(after))
	for i, l := range after {
		afterKeys[i] = normalizeForMatch(strings.TrimRight(l, " \t\r"))
	}
	aligned := alignLines(beforeKeys, afterKeys)
	var b strings.Builder
	for idx, line := range after {
		b.WriteString(line)
		if idx < len(after)-1 {
			src := aligned[idx]
			if src >= 0 && src < len(endings) {
				b.WriteString(endings[src])
			} else {
				b.WriteString(fallback)
			}
		}
	}
	return b.String()
}

func countBefore(positions []int, offset int) int {
	low, high := 0, len(positions)
	for low < high {
		mid := (low + high) >> 1
		if positions[mid] < offset {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

func matchView(source, oldString, newString string) ([]editMatch, func(editMatch) string) {
	// Build LF view and record removed '\r' positions in view coordinates.
	var removed []int
	var viewBuilder strings.Builder
	viewBuilder.Grow(len(source))
	removedIdx := 0
	for i := 0; i < len(source); i++ {
		if source[i] == '\r' && i+1 < len(source) && source[i+1] == '\n' {
			removed = append(removed, i-removedIdx)
			removedIdx++
			continue
		}
		viewBuilder.WriteByte(source[i])
	}
	view := viewBuilder.String()
	fileEnding := dominantLineEnding(source, "\n")
	search := strings.ReplaceAll(oldString, "\r\n", "\n")
	replacement := strings.ReplaceAll(newString, "\r\n", "\n")

	matches := findByteOccurrences(view, search)
	if len(matches) == 0 {
		normView, normMap := normalizeWithByteMap(view)
		normSearch := normalizeForMatch(search)
		normMatches := findByteOccurrences(normView, normSearch)
		for _, nm := range normMatches {
			matches = append(matches, editMatch{
				start: normMap[nm.start],
				end:   normMap[nm.end],
			})
		}
	}
	if len(matches) == 0 {
		matches = findLineOccurrences(view, search)
	}

	mapped := make([]editMatch, len(matches))
	for i, m := range matches {
		mapped[i] = editMatch{
			start: m.start + countBefore(removed, m.start),
			end:   m.end + countBefore(removed, m.end),
		}
	}
	replaceFn := func(m editMatch) string {
		region := source[m.start:m.end]
		return withRegionEndings(region, replacement, dominantLineEnding(region, fileEnding))
	}
	return mapped, replaceFn
}

func missHint(source, oldString, newString string) string {
	view := strings.ReplaceAll(source, "\r\n", "\n")
	replacement := strings.ReplaceAll(newString, "\r\n", "\n")
	if len(strings.TrimSpace(replacement)) >= 20 && strings.Contains(normalizeForMatch(view), normalizeForMatch(replacement)) {
		return "newString is already in the file, so this edit may already be applied."
	}
	key := func(line string) string {
		fields := strings.Fields(normalizeForMatch(line))
		return strings.Join(fields, " ")
	}
	distinct := func(line string) bool {
		for _, r := range line {
			if unicode.IsLetter(r) || unicode.IsNumber(r) {
				return true
			}
		}
		return false
	}
	lines := strings.Split(view, "\n")
	search := strings.Split(strings.ReplaceAll(oldString, "\r\n", "\n"), "\n")
	positions := map[string][]int{}
	for idx, line := range lines {
		v := key(line)
		if !distinct(v) {
			continue
		}
		positions[v] = append(positions[v], idx)
	}
	votes := map[int]int{}
	wanted := 0
	for offset, line := range search {
		v := key(line)
		if !distinct(v) {
			continue
		}
		wanted++
		for _, idx := range positions[v] {
			votes[idx-offset]++
		}
	}
	bestStart, bestCount := 0, 0
	for st, cnt := range votes {
		if cnt > bestCount || (cnt == bestCount && st < bestStart) {
			bestStart = st
			bestCount = cnt
		}
	}
	if bestCount == 0 || bestCount*2 < wanted {
		return ""
	}
	var matched []int
	for offset, line := range search {
		v := key(line)
		idx := bestStart + offset
		if v != "" && idx >= 0 && idx < len(lines) && key(lines[idx]) == v {
			matched = append(matched, idx)
		}
	}
	if len(matched) == 0 {
		return ""
	}
	from := matched[0]
	to := matched[len(matched)-1] + 1
	if to > from+12 {
		to = from + 12
	}
	out := []string{"The closest lines in the file:"}
	for idx := from; idx < to; idx++ {
		line := lines[idx]
		if len(line) > 200 {
			line = line[:200] + "…"
		}
		out = append(out, fmt.Sprintf("%d: %s", idx+1, line))
	}
	return strings.Join(out, "\n")
}

// ComputeFileDiff produces line addition/deletion counts and a compact unified diff preview.
func ComputeFileDiff(fileLabel, beforeRaw, afterRaw string) FileDiff {
	beforeNorm := strings.ReplaceAll(strings.TrimPrefix(beforeRaw, utf8BOM), "\r\n", "\n")
	afterNorm := strings.ReplaceAll(strings.TrimPrefix(afterRaw, utf8BOM), "\r\n", "\n")

	status := "modified"
	if beforeRaw == "" && afterRaw != "" {
		status = "added"
	} else if beforeRaw != "" && afterRaw == "" {
		status = "deleted"
	}

	var beforeLines, afterLines []string
	if beforeNorm != "" {
		beforeLines = strings.Split(strings.TrimSuffix(beforeNorm, "\n"), "\n")
	}
	if afterNorm != "" {
		afterLines = strings.Split(strings.TrimSuffix(afterNorm, "\n"), "\n")
	}

	// Guard LCS size on huge files (> 2500 lines): fall back to prefix/suffix trim diff.
	if len(beforeLines)*len(afterLines) > 2_500_000 {
		p := 0
		for p < len(beforeLines) && p < len(afterLines) && beforeLines[p] == afterLines[p] {
			p++
		}
		sb, sa := len(beforeLines)-1, len(afterLines)-1
		for sb >= p && sa >= p && beforeLines[sb] == afterLines[sa] {
			sb--
			sa--
		}
		del := sb - p + 1
		add := sa - p + 1
		var patch strings.Builder
		fmt.Fprintf(&patch, "--- a/%s\n+++ b/%s\n@@ -%d,%d +%d,%d @@\n", fileLabel, fileLabel, p+1, del, p+1, add)
		limit := 80
		for i := p; i <= sb && limit > 0; i++ {
			patch.WriteString("-" + beforeLines[i] + "\n")
			limit--
		}
		for i := p; i <= sa && limit > 0; i++ {
			patch.WriteString("+" + afterLines[i] + "\n")
			limit--
		}
		return FileDiff{File: fileLabel, Additions: add, Deletions: del, Status: status, Patch: patch.String()}
	}

	// Standard LCS diff with 3 lines of context
	m, n := len(beforeLines), len(afterLines)
	w := n + 1
	dp := make([]int, (m+1)*w)
	for i := m - 1; i >= 0; i-- {
		for j := n - 1; j >= 0; j-- {
			if beforeLines[i] == afterLines[j] {
				dp[i*w+j] = dp[(i+1)*w+j+1] + 1
			} else if dp[(i+1)*w+j] >= dp[i*w+j+1] {
				dp[i*w+j] = dp[(i+1)*w+j]
			} else {
				dp[i*w+j] = dp[i*w+j+1]
			}
		}
	}

	type op struct {
		kind byte // ' ', '-', '+'
		line string
		bLn  int
		aLn  int
	}
	var ops []op
	i, j := 0, 0
	add, del := 0, 0
	for i < m && j < n {
		if beforeLines[i] == afterLines[j] {
			ops = append(ops, op{kind: ' ', line: beforeLines[i], bLn: i + 1, aLn: j + 1})
			i++
			j++
		} else if dp[(i+1)*w+j] >= dp[i*w+j+1] {
			ops = append(ops, op{kind: '-', line: beforeLines[i], bLn: i + 1, aLn: j + 1})
			del++
			i++
		} else {
			ops = append(ops, op{kind: '+', line: afterLines[j], bLn: i + 1, aLn: j + 1})
			add++
			j++
		}
	}
	for i < m {
		ops = append(ops, op{kind: '-', line: beforeLines[i], bLn: i + 1, aLn: j + 1})
		del++
		i++
	}
	for j < n {
		ops = append(ops, op{kind: '+', line: afterLines[j], bLn: i + 1, aLn: j + 1})
		add++
		j++
	}

	// Build hunks with 3 lines of context
	keep := make([]bool, len(ops))
	for idx, o := range ops {
		if o.kind != ' ' {
			lo := idx - 3
			if lo < 0 {
				lo = 0
			}
			hi := idx + 3
			if hi >= len(ops) {
				hi = len(ops) - 1
			}
			for k := lo; k <= hi; k++ {
				keep[k] = true
			}
		}
	}

	var patch strings.Builder
	if add > 0 || del > 0 {
		fmt.Fprintf(&patch, "--- a/%s\n+++ b/%s\n", fileLabel, fileLabel)
		idx := 0
		emitted := 0
		for idx < len(ops) && emitted < 200 {
			if !keep[idx] {
				idx++
				continue
			}
			end := idx
			for end < len(ops) && keep[end] {
				end++
			}
			bStart := ops[idx].bLn
			aStart := ops[idx].aLn
			bCnt, aCnt := 0, 0
			for k := idx; k < end; k++ {
				if ops[k].kind != '+' {
					bCnt++
				}
				if ops[k].kind != '-' {
					aCnt++
				}
			}
			fmt.Fprintf(&patch, "@@ -%d,%d +%d,%d @@\n", bStart, bCnt, aStart, aCnt)
			for k := idx; k < end && emitted < 200; k++ {
				patch.WriteByte(ops[k].kind)
				patch.WriteString(ops[k].line)
				patch.WriteByte('\n')
				emitted++
			}
			idx = end
		}
	}

	return FileDiff{
		File:      fileLabel,
		Additions: add,
		Deletions: del,
		Status:    status,
		Patch:     patch.String(),
	}
}
