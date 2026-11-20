//go:build linux || windows

package ai

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"

	"aurora3/internal/filetxn"
	"aurora3/internal/statecrypt"
)

const sessionBytesMax = filetxn.MaxFileBytes
const sessionJournalMax = 8 << 20
const sessionCacheMax = 8

var sessionIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)

// The JSON checkpoint remains readable by old installations. Revisions make a
// crash between checkpoint replacement and journal rotation idempotent.
type sessionCheckpoint struct {
	Session
	Revision uint64 `json:"storage_revision,omitempty"`
}
type sessionChange struct {
	Index   int     `json:"index"`
	Message Message `json:"message"`
}
type sessionDelta struct {
	Revision uint64          `json:"revision"`
	Meta     Session         `json:"meta"`
	Length   int             `json:"length"`
	Changes  []sessionChange `json:"changes"`
}
type sessionStamp struct {
	Size     int64 `json:"size"`
	Modified int64 `json:"modified"`
}
type sessionIndex struct {
	Version       int            `json:"version"`
	Meta          Session        `json:"meta"`
	Summary       SessionSummary `json:"summary"`
	Attachments   []string       `json:"attachments"`
	Trees         []string       `json:"trees"`
	Base, Journal sessionStamp
	Revision      uint64 `json:"revision"`
}
type sessionIndexFile struct {
	Index sessionIndex `json:"index"`
	CRC32 uint32       `json:"crc32"`
}
type sessionRecord struct {
	index    sessionIndex
	baseline *Session
	revision uint64
	lazy     bool
	used     uint64
	torn     int64 // valid prefix; -1 means complete
	unsaved  bool
}

func sessionFileStamp(path string) (sessionStamp, error) {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return sessionStamp{}, nil
	}
	if err != nil {
		return sessionStamp{}, err
	}
	if !info.Mode().IsRegular() {
		return sessionStamp{}, errors.New("会话存储不是普通文件")
	}
	return sessionStamp{info.Size(), info.ModTime().UnixNano()}, nil
}
func readSessionFile(path string, max int64) ([]byte, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > max {
		return nil, errors.New("会话文件超过存储预算")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !os.SameFile(fi, info) {
		return nil, errors.New("会话存储在打开时已变化")
	}
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if int64(len(data)) > max {
		return nil, errors.New("会话文件超过存储预算")
	}
	return data, err
}

func protectAIRecord(scope, path string, data []byte) ([]byte, error) {
	if codec := statecrypt.Current(); codec != nil {
		return codec.Seal("ai:"+scope+":"+filepath.Base(path), data)
	}
	return data, nil
}

func openAIRecord(scope, path string, data []byte) ([]byte, error) {
	codec := statecrypt.Current()
	if codec == nil && !statecrypt.Protected(data) {
		return data, nil
	}
	return codec.Open("ai:"+scope+":"+filepath.Base(path), data)
}

func readAIRecord(scope, path string, max int64) ([]byte, error) {
	stored, err := readSessionFile(path, max+int64(statecrypt.Overhead))
	if err != nil {
		return nil, err
	}
	data, err := openAIRecord(scope, path, stored)
	if err == nil && int64(len(data)) > max {
		return nil, errors.New("AI 存储记录超过预算")
	}
	return data, err
}

func writeAIRecord(scope, path string, data []byte) error {
	stored, err := protectAIRecord(scope, path, data)
	if err != nil {
		return err
	}
	return atomicWriteFile(path, stored, 0600)
}
func sessionSummary(s *Session) SessionSummary {
	return SessionSummary{ID: s.ID, ParentID: s.ParentID, Title: s.Title, Pinned: s.Pinned,
		Root: s.Root, Workdir: s.Workdir, Agent: s.Agent, Model: s.Model,
		Preview: sessionPreview(s), MessageCount: len(s.Messages), CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt}
}
func sessionReferences(s *Session) (attachments, trees []string) {
	a, t := map[string]bool{}, map[string]bool{}
	var part func(Part)
	part = func(p Part) {
		if p.AttachmentID != "" {
			a[p.AttachmentID] = true
		}
		for _, child := range p.Attachments {
			part(child)
		}
	}
	for _, m := range s.Messages {
		for _, p := range m.Parts {
			part(p)
		}
		if m.Snapshot != nil {
			if m.Snapshot.Start != "" {
				t[m.Snapshot.Start] = true
			}
			if m.Snapshot.End != "" {
				t[m.Snapshot.End] = true
			}
		}
	}
	for _, item := range s.Inbox {
		for _, ref := range item.Attachments {
			if ref.AttachmentID != "" {
				a[ref.AttachmentID] = true
			}
		}
	}
	for id := range a {
		attachments = append(attachments, id)
	}
	for id := range t {
		trees = append(trees, id)
	}
	sort.Strings(attachments)
	sort.Strings(trees)
	return
}
func makeSessionIndex(s *Session, revision uint64) sessionIndex {
	meta := Session{ID: s.ID, ParentID: s.ParentID, Title: s.Title, Pinned: s.Pinned,
		Root: s.Root, Workdir: s.Workdir, Agent: s.Agent, Model: s.Model, Protocol: s.Protocol,
		CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt}
	a, t := sessionReferences(s)
	return sessionIndex{Version: 1, Meta: meta, Summary: sessionSummary(s), Attachments: a, Trees: t, Revision: revision}
}
func indexMatches(dir, id string, idx sessionIndex) bool {
	base, err := sessionFileStamp(filepath.Join(dir, id+".json"))
	if err != nil || base == (sessionStamp{}) || base != idx.Base {
		return false
	}
	journal, err := sessionFileStamp(filepath.Join(dir, id+".journal"))
	return err == nil && journal == idx.Journal
}
func stampSessionIndex(dir string, idx sessionIndex) (sessionIndex, error) {
	var err error
	idx.Base, err = sessionFileStamp(filepath.Join(dir, idx.Meta.ID+".json"))
	if err != nil {
		return idx, err
	}
	idx.Journal, err = sessionFileStamp(filepath.Join(dir, idx.Meta.ID+".journal"))
	return idx, err
}
func writeSessionIndex(dir string, idx sessionIndex) sessionIndex {
	idx, err := stampSessionIndex(dir, idx)
	if err != nil {
		return idx
	}
	body, err := json.Marshal(idx)
	if err != nil {
		return idx
	}
	data, err := json.Marshal(sessionIndexFile{Index: idx, CRC32: crc32.ChecksumIEEE(body)})
	// Derived cache only: a failure here never changes a durable commit's result.
	if err == nil {
		_ = writeAIRecord("index", filepath.Join(dir, idx.Meta.ID+".index"), data)
	}
	return idx
}
func readSessionIndex(dir, id string) (sessionIndex, bool) {
	data, err := readAIRecord("index", filepath.Join(dir, id+".index"), 2<<20)
	if err != nil {
		return sessionIndex{}, false
	}
	var file sessionIndexFile
	if json.Unmarshal(data, &file) != nil {
		return sessionIndex{}, false
	}
	idx := file.Index
	body, err := json.Marshal(idx)
	valid := err == nil && crc32.ChecksumIEEE(body) == file.CRC32 &&
		idx.Version == 1 && idx.Meta.ID == id && idx.Summary.ID == id &&
		idx.Meta.Messages == nil && indexMatches(dir, id, idx)
	return idx, valid
}

func readSessionDisk(dir, id string) (*Session, *sessionRecord, error) {
	before, err := stampSessionIndex(dir, sessionIndex{Meta: Session{ID: id}})
	if err != nil {
		return nil, nil, err
	}
	data, err := readAIRecord("checkpoint", filepath.Join(dir, id+".json"), sessionBytesMax)
	if err != nil {
		return nil, nil, err
	}
	var cp sessionCheckpoint
	if err := json.Unmarshal(data, &cp); err != nil {
		return nil, nil, err
	}
	if cp.ID != id {
		return nil, nil, errors.New("会话文件与 ID 不匹配")
	}
	if cp.Messages == nil {
		cp.Messages = []Message{}
	}
	r := &sessionRecord{revision: cp.Revision, torn: -1}
	log, err := readSessionFile(filepath.Join(dir, id+".journal"), sessionBytesMax)
	if err != nil && !os.IsNotExist(err) {
		return nil, nil, err
	}
	for offset := 0; offset < len(log); {
		start := offset
		if len(log)-offset < 8 {
			r.torn = int64(start)
			break
		}
		size, checksum := int(binary.BigEndian.Uint32(log[offset:])), binary.BigEndian.Uint32(log[offset+4:])
		if size < 1 || size > sessionBytesMax+statecrypt.Overhead {
			return nil, nil, errors.New("会话日志记录长度损坏")
		}
		offset += 8
		if len(log)-offset < size {
			r.torn = int64(start)
			break
		}
		payload := log[offset : offset+size]
		offset += size
		if crc32.ChecksumIEEE(payload) != checksum {
			return nil, nil, errors.New("会话日志校验失败，已保留原记录")
		}
		payload, err = openAIRecord(fmt.Sprintf("delta:%d", start), id+".journal", payload)
		if err != nil {
			return nil, nil, err
		}
		var delta sessionDelta
		if err := json.Unmarshal(payload, &delta); err != nil {
			return nil, nil, err
		}
		if delta.Revision <= cp.Revision {
			continue
		} // completed checkpoint rotation
		if delta.Revision != r.revision+1 || delta.Meta.ID != id || delta.Length < 0 || delta.Length > 100000 {
			return nil, nil, errors.New("会话日志序号或范围损坏")
		}
		previous := cp.Messages
		messages := make([]Message, delta.Length)
		copy(messages, previous)
		seen := map[int]bool{}
		for _, change := range delta.Changes {
			if change.Index < 0 || change.Index >= len(messages) || seen[change.Index] {
				return nil, nil, errors.New("会话日志消息范围损坏")
			}
			seen[change.Index] = true
			messages[change.Index] = change.Message
		}
		for i := len(previous); i < len(messages); i++ {
			if !seen[i] {
				return nil, nil, errors.New("会话日志缺少新增消息")
			}
		}
		cp.Session = delta.Meta
		cp.Messages = messages
		r.revision = delta.Revision
	}
	r.baseline = &cp.Session
	r.index = makeSessionIndex(&cp.Session, r.revision)
	// Reading/searching a body never rewrites or fsyncs the derived cache.
	r.index, err = stampSessionIndex(dir, r.index)
	if err != nil {
		return nil, nil, err
	}
	if before.Base != r.index.Base || before.Journal != r.index.Journal {
		return nil, nil, errors.New("读取期间会话文件发生变化")
	}
	return &cp.Session, r, nil
}

// Startup keeps metadata only. Legacy/missing indexes are rebuilt one session
// at a time, then their bodies are released, so migration has bounded memory.
func (e *Env) loadSessionIndex() {
	dir := e.sessionsDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !os.IsNotExist(err) {
			e.storeError = err
		}
		return
	}
	seen := map[string]bool{}
	for _, entry := range entries {
		ext := filepath.Ext(entry.Name())
		if ext != ".json" && ext != ".journal" && ext != ".index" {
			continue
		}
		id := entry.Name()[:len(entry.Name())-len(ext)]
		if seen[id] {
			continue
		}
		seen[id] = true
		if !sessionIDPattern.MatchString(id) {
			e.storeError = errors.New("会话目录含无效 ID")
			continue
		}
		idx, valid := readSessionIndex(dir, id)
		var r *sessionRecord
		if valid {
			r = &sessionRecord{index: idx, revision: idx.Revision, torn: -1}
		} else {
			_, r, err = readSessionDisk(dir, id)
			if err != nil {
				e.sessionErrors[id] = err
				e.sessions[id] = &Session{ID: id, Title: id}
				continue
			}
			if r.torn < 0 {
				r.index = writeSessionIndex(dir, r.index)
			} else {
				// Incomplete journals must be replayed, never hidden by a cache.
				_ = os.Remove(filepath.Join(dir, id+".index"))
			}
		}
		r.lazy = true
		r.baseline = nil
		meta := r.index.Meta
		meta.Messages = nil
		e.records[id] = r
		e.sessions[id] = &meta
	}
}
func (e *Env) waitSessionLocked(id string) {
	for e.sessionIO[id] != nil {
		done := e.sessionIO[id]
		e.mu.Unlock()
		<-done
		e.mu.Lock()
	}
}

// Retains the global lock on return. Disk work owns this session's lease only.
func (e *Env) sessionIOLocked(id string, work func() error) error {
	e.waitSessionLocked(id)
	done := make(chan struct{})
	e.sessionIO[id] = done
	e.mu.Unlock()
	err := work()
	e.mu.Lock()
	delete(e.sessionIO, id)
	close(done)
	return err
}
func (e *Env) sessionLocked(id string) *Session {
	e.waitSessionLocked(id)
	if e.sessionErrors[id] != nil {
		return nil
	}
	r := e.records[id]
	if r != nil && r.lazy {
		var s *Session
		var loaded *sessionRecord
		err := e.sessionIOLocked(id, func() error {
			var err error
			s, loaded, err = readSessionDisk(e.sessionsDir(), id)
			if err == nil {
				sCopy := cloneSession(s)
				s = &sCopy
				recoverInterruptedTools(s)
			}
			return err
		})
		if err != nil {
			e.sessionErrors[id] = err
			return nil
		}
		e.records[id] = loaded
		e.sessions[id] = s
		r = loaded
	}
	e.storeClock++
	if r != nil {
		r.used = e.storeClock
	}
	e.trimSessionsLocked(id)
	return e.sessions[id]
}
func (e *Env) trimSessionsLocked(keep string) {
	type candidate struct {
		id   string
		used uint64
	}
	var candidates []candidate
	total := int64(0)
	count := 0
	for id, r := range e.records {
		if r.lazy {
			continue
		}
		count++
		total += r.index.Base.Size + r.index.Journal.Size
		if id != keep && !r.unsaved && e.running[id] == nil && e.maintenance[id] == nil && e.sessionIO[id] == nil {
			candidates = append(candidates, candidate{id, r.used})
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].used < candidates[j].used })
	for _, c := range candidates {
		if count <= sessionCacheMax && total <= sessionBytesMax {
			break
		}
		r := e.records[c.id]
		meta := r.index.Meta
		meta.Messages = nil
		e.sessions[c.id] = &meta
		r.lazy = true
		r.baseline = nil
		count--
		total -= r.index.Base.Size + r.index.Journal.Size
	}
}
func frameSessionDelta(data []byte) []byte {
	frame := make([]byte, 8+len(data))
	binary.BigEndian.PutUint32(frame, uint32(len(data)))
	binary.BigEndian.PutUint32(frame[4:], crc32.ChecksumIEEE(data))
	copy(frame[8:], data)
	return frame
}
func appendSessionDelta(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	offset, err := f.Seek(0, io.SeekEnd)
	if err != nil {
		return err
	}
	stored, err := protectAIRecord(fmt.Sprintf("delta:%d", offset), path, data)
	if err != nil {
		return err
	}
	_, err = f.Write(frameSessionDelta(stored))
	if err == nil {
		err = f.Sync()
	}
	if err != nil {
		if rollback := f.Truncate(offset); rollback != nil {
			return fmt.Errorf("%w; journal rollback: %v", err, rollback)
		}
		if rollback := f.Sync(); rollback != nil {
			return fmt.Errorf("%w; journal rollback sync: %v", err, rollback)
		}
	}
	return err
}
func saveSessionDisk(dir string, s *Session, r *sessionRecord) (*sessionRecord, error) {
	if !sessionIDPattern.MatchString(s.ID) {
		return r, errors.New("无效会话 ID")
	}
	if err := filetxn.CheckReady(); err != nil {
		return r, err
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return r, err
	}
	if r == nil {
		// A missing in-memory record is not permission to replace existing
		// state. In particular, never overwrite an unreadable checkpoint.
		for _, ext := range []string{".json", ".journal", ".index"} {
			if _, err := os.Lstat(filepath.Join(dir, s.ID+ext)); !os.IsNotExist(err) {
				if err != nil {
					return r, err
				}
				return r, errors.New("已有会话记录，拒绝用新会话覆盖")
			}
		}
	}
	if r != nil && !indexMatches(dir, s.ID, r.index) {
		return r, errors.New("会话文件已在外部变化，请重新打开 agent 后恢复")
	}
	delta := sessionDelta{Revision: 1, Meta: *s, Length: len(s.Messages)}
	delta.Meta.Messages = nil
	var previous []Message
	if r != nil {
		delta.Revision = r.revision + 1
		previous = r.baseline.Messages
	}
	for i, m := range s.Messages {
		if i >= len(previous) || !reflect.DeepEqual(m, previous[i]) {
			delta.Changes = append(delta.Changes, sessionChange{i, m})
		}
	}
	data, err := json.Marshal(delta)
	if err != nil {
		return r, err
	}
	if len(data) > sessionBytesMax {
		return r, errors.New("会话增量超过 64 MiB")
	}
	// Decode changed messages only to own immutable copies and remove credentials.
	var clean sessionDelta
	if err := json.Unmarshal(data, &clean); err != nil {
		return r, err
	}
	next := clean.Meta
	next.Messages = make([]Message, len(s.Messages))
	copy(next.Messages, previous)
	for _, change := range clean.Changes {
		next.Messages[change.Index] = change.Message
	}
	nextRecord := &sessionRecord{baseline: &next, revision: delta.Revision, torn: -1}
	extra := 8
	if statecrypt.Current() != nil {
		extra += statecrypt.Overhead
	}
	checkpoint := r == nil || r.index.Journal.Size+int64(len(data)+extra) > sessionJournalMax ||
		r.index.Base.Size+r.index.Journal.Size+int64(len(data)+extra) > sessionBytesMax || delta.Revision%64 == 0
	if r != nil && r.torn >= 0 {
		path := filepath.Join(dir, s.ID+".journal")
		log, err := readSessionFile(path, sessionBytesMax)
		if err != nil {
			return r, err
		}
		if err := writeAIRecord("torn-journal", path+".torn-"+NewID("log"), log); err != nil {
			return r, err
		}
		if !checkpoint {
			if err := atomicWriteFile(path, log[:r.torn], 0600); err != nil {
				return r, err
			}
		}
	}
	if checkpoint {
		full, err := json.Marshal(sessionCheckpoint{Session: next, Revision: delta.Revision})
		if err != nil {
			return r, err
		}
		if len(full)+extra-8 > sessionBytesMax {
			return r, errors.New("会话超过 64 MiB，请导出或拆分")
		}
		if err := writeAIRecord("checkpoint", filepath.Join(dir, s.ID+".json"), full); err != nil {
			return r, err
		}
		// The checkpoint is already durable. Old records are harmless on replay.
		_ = atomicWriteFile(filepath.Join(dir, s.ID+".journal"), nil, 0600)
	} else {
		if err := appendSessionDelta(filepath.Join(dir, s.ID+".journal"), data); err != nil {
			return r, err
		}
	}
	nextRecord.index = writeSessionIndex(dir, makeSessionIndex(&next, delta.Revision))
	return nextRecord, nil
}
func (e *Env) persistSessionLocked(s *Session) error {
	if e.sessionsDir() == "" {
		return nil
	}
	if err := e.sessionErrors[s.ID]; err != nil {
		return err
	}
	r := e.records[s.ID]
	var next *sessionRecord
	err := e.sessionIOLocked(s.ID, func() error {
		if e.beforeSessionWrite != nil {
			if err := e.beforeSessionWrite(s.ID); err != nil {
				return err
			}
		}
		var err error
		next, err = saveSessionDisk(e.sessionsDir(), s, r)
		return err
	})
	if err == nil {
		e.storeClock++
		next.used = e.storeClock
		e.records[s.ID] = next
	}
	if err != nil && r != nil {
		r.unsaved = true
	}
	return err
}

// Revert publishes a checkpoint and clears its log in the same file transaction
// as restored workspace files. Stale indexes are automatically rebuilt.
func (e *Env) commitSessionRevertLocked(ctx context.Context, s *Session, work string, changes []filetxn.Change) error {
	r := e.records[s.ID]
	var next *sessionRecord
	err := e.sessionIOLocked(s.ID, func() error {
		if e.StateDir != "" {
			dir := e.sessionsDir()
			if r != nil && !indexMatches(dir, s.ID, r.index) {
				return errors.New("会话文件已在外部变化，回退已取消")
			}
			if err := os.MkdirAll(dir, 0700); err != nil {
				return err
			}
			revision := uint64(1)
			if r != nil {
				revision = r.revision + 1
			}
			data, err := json.Marshal(sessionCheckpoint{Session: *s, Revision: revision})
			if err != nil {
				return err
			}
			data, err = protectAIRecord("checkpoint", s.ID+".json", data)
			if err != nil {
				return err
			}
			if len(data) > sessionBytesMax {
				return errors.New("回退后的会话超过 64 MiB，已取消整批修改")
			}
			root, err := os.OpenRoot(dir)
			if err != nil {
				return err
			}
			defer root.Close()
			for _, item := range []struct {
				suffix string
				data   []byte
			}{{".json", data}, {".journal", nil}} {
				before, err := filetxn.Read(root, s.ID+item.suffix)
				if err != nil {
					return err
				}
				changes = append(changes, filetxn.Change{Root: dir, Path: s.ID + item.suffix, Before: before,
					After: filetxn.State{Exists: true, Data: item.data, Mode: 0600}})
			}
			clean := cloneSession(s)
			next = &sessionRecord{baseline: &clean, revision: revision, torn: -1, index: makeSessionIndex(&clean, revision)}
		}
		if err := e.fileTransactions(work).Commit(ctx, changes); err != nil {
			return err
		}
		if next != nil {
			next.index = writeSessionIndex(e.sessionsDir(), next.index)
		}
		return nil
	})
	if err == nil && next != nil {
		e.records[s.ID] = next
	}
	return err
}

func (e *Env) sessionStorageError(id string) error {
	if err := e.sessionErrors[id]; err != nil {
		return fmt.Errorf("会话 %s 读取失败（原记录已保留）: %w", id, err)
	}
	return fmt.Errorf("session not found: %s", id)
}
func (e *Env) validateSessionReferencesLocked() error {
	if e.storeError != nil {
		return e.storeError
	}
	if len(e.sessionErrors) > 0 {
		return errors.New("存在无法读取的会话，保留全部附件及快照；修复记录后再清理")
	}
	if len(e.sessionIO) > 0 {
		return errors.New("会话正在落盘，请稍后清理")
	}
	for id, r := range e.records {
		if !indexMatches(e.sessionsDir(), id, r.index) {
			return errors.New("会话存储已变化，重新打开 agent 验证引用后再清理")
		}
	}
	return nil
}

func (e *Env) deleteSessionsDiskLocked(id string, ids []string) error {
	dir := e.sessionsDir()
	if dir == "" {
		return nil
	}
	return e.sessionIOLocked(id, func() error {
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			return nil
		}
		root, err := os.OpenRoot(dir)
		if err != nil {
			return err
		}
		defer root.Close()
		// Stat the complete batch first: deleting a large descendant tree must
		// not load every body before discovering the transaction's size limit.
		var names []string
		var total int64
		for _, id := range ids {
			if !sessionIDPattern.MatchString(id) {
				return errors.New("无效会话 ID")
			}
			for _, suffix := range []string{".json", ".journal", ".index"} {
				name := id + suffix
				info, err := root.Lstat(name)
				if os.IsNotExist(err) {
					continue
				}
				if err != nil {
					return err
				}
				if !info.Mode().IsRegular() || info.Size() > filetxn.MaxFileBytes {
					return errors.New("会话删除要求普通文件且每个文件不超过 64 MiB")
				}
				names = append(names, name)
				total += info.Size()
				if len(names) > filetxn.MaxChanges || total > filetxn.MaxTransactionBytes {
					return fmt.Errorf("整批删除超过 %d 个文件或 %d MiB；请先删除部分子会话，原记录未修改",
						filetxn.MaxChanges, filetxn.MaxTransactionBytes>>20)
				}
			}
		}
		changes := make([]filetxn.Change, 0, len(names))
		total = 0
		for _, name := range names {
			before, err := filetxn.Read(root, name)
			if err != nil {
				return err
			}
			total += int64(len(before.Data))
			if total > filetxn.MaxTransactionBytes {
				return errors.New("读取期间会话删除超过 256 MiB，原记录未修改")
			}
			if before.Exists {
				changes = append(changes, filetxn.Change{Root: dir, Path: name, Before: before})
			}
		}
		return e.fileTransactions().Commit(context.Background(), changes)
	})
}

// Search scans one body at a time without filling the interactive session cache.
func (e *Env) searchSession(ctx context.Context, id string) (*Session, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.waitSessionLocked(id)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := e.sessionErrors[id]; err != nil {
		return nil, err
	}
	if r := e.records[id]; r != nil && r.lazy {
		var s *Session
		err := e.sessionIOLocked(id, func() error {
			var err error
			s, _, err = readSessionDisk(e.sessionsDir(), id)
			return err
		})
		if err != nil {
			e.sessionErrors[id] = err
		}
		return s, err
	}
	if s := e.sessions[id]; s != nil {
		var cp Session
		_ = e.sessionIOLocked(id, func() error { cp = cloneSession(s); return nil })
		return &cp, nil
	}
	return nil, e.sessionStorageError(id)
}
