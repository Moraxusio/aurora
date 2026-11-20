// Package filetxn coordinates agent-owned file commits and crash recovery.
// Network reads and approval waits must happen before taking CommitMu.
package filetxn

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"aurora3/internal/statecrypt"
)

var CommitMu sync.Mutex

// A session checkpoint can occupy 64 MiB. Its before/after versions, log and
// workspace edits must fit in the same bounded recovery journal.
const MaxFileBytes = 64 << 20
const MaxTransactionBytes = 256 << 20
const MaxChanges = 512

var ErrConflict = errors.New("file changed since preview")
var ErrRecoveryRequired = errors.New("file transaction requires recovery before further changes")

// Session persistence also checks this gate outside CommitMu. Concurrent
// readers must remain safe while a workspace transaction latches a fault.
var recoveryFaults sync.Map // directory -> error

func CheckReady() error {
	var failure error
	recoveryFaults.Range(func(_, value any) bool {
		failure = value.(error)
		return false
	})
	return failure
}

func (m *Manager) requireRecovery(cause error) error {
	err := fmt.Errorf("%w: %w", ErrRecoveryRequired, cause)
	recoveryFaults.Store(m.Directory, err)
	return err
}

// State is an exact file version. Mode zero in an expected state checks bytes
// and existence only (e.g. Git snapshots do not retain all permission bits).
type State struct {
	Exists bool        `json:"exists"`
	Data   []byte      `json:"data,omitempty"`
	Mode   os.FileMode `json:"mode,omitempty"`
	UID    int         `json:"uid"`
	GID    int         `json:"gid"`
}

type Change struct {
	Root   string `json:"root"`
	Path   string `json:"path"`
	Before State  `json:"before"`
	After  State  `json:"after"`
}

type journal struct {
	Format  int      `json:"format"`
	Changes []Change `json:"changes"`
}

type Manager struct {
	Directory  string
	protection *statecrypt.Codec
	// Configured roots plus the private state directory. Recovery refuses a
	// journal whose targets are outside these capabilities.
	Roots []string
	// Test crash injection runs after a durable file replacement.
	afterApply   func(int) error
	afterMarker  func() error
	removeMarker func(*os.Root, string) error
	syncJournal  func(*os.Root) error
}

func New(stateDir string, roots []string) *Manager {
	m := &Manager{Roots: append([]string(nil), roots...), protection: statecrypt.Current()}
	if stateDir != "" {
		m.Directory = filepath.Join(stateDir, "file-transactions")
		m.Roots = append(m.Roots, stateDir)
	}
	return m
}

func validPath(p string) bool {
	return p != "." && filepath.IsLocal(p) && filepath.Clean(p) == p
}

func (m *Manager) allowed(root string) bool {
	actual, err := filepath.EvalSymlinks(root)
	if err != nil {
		return false
	}
	for _, base := range m.Roots {
		canonical, err := filepath.EvalSymlinks(base)
		if err != nil {
			continue
		}
		rel, err := filepath.Rel(canonical, actual)
		if err == nil && (rel == "." || filepath.IsLocal(rel)) {
			return true
		}
	}
	return false
}

func Read(root *os.Root, rel string) (State, error) {
	s := State{UID: -1, GID: -1}
	fi, err := root.Lstat(rel)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return s, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > MaxFileBytes {
		return s, fmt.Errorf("transaction requires a regular file up to %d bytes: %s", MaxFileBytes, rel)
	}
	f, err := root.Open(rel)
	if err != nil {
		return s, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil {
		return s, err
	}
	if !os.SameFile(fi, opened) {
		return s, fmt.Errorf("%w: %s", ErrConflict, rel)
	}
	s.Data, err = io.ReadAll(io.LimitReader(f, MaxFileBytes+1))
	if err != nil {
		return s, err
	}
	if len(s.Data) > MaxFileBytes {
		return s, fmt.Errorf("file grew beyond transaction limit: %s", rel)
	}
	s.Exists, s.Mode = true, fi.Mode().Perm()
	s.UID, s.GID = ownership(fi)
	return s, nil
}

func same(actual, expected State) bool {
	return actual.Exists == expected.Exists && (!actual.Exists ||
		(bytes.Equal(actual.Data, expected.Data) && (expected.Mode == 0 || modesEqual(actual.Mode, expected.Mode))))
}

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

// Put never follows the final symlink and confines all parent traversal to root.
// The caller holds CommitMu and has validated the expected version.
func Put(root *os.Root, rel string, state State) error {
	if !validPath(rel) {
		return fmt.Errorf("invalid transaction path: %s", rel)
	}
	if !state.Exists {
		err := root.Remove(rel)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		return syncDirectory(root, filepath.Dir(rel))
	}
	if err := root.MkdirAll(filepath.Dir(rel), 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(filepath.Dir(rel), ".aurora-txn-"+newID())
	mode := state.Mode
	if mode == 0 {
		mode = 0o644
	}
	f, err := root.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	defer root.Remove(tmp)
	if _, err = f.Write(state.Data); err == nil {
		err = setOwnership(f, state.UID, state.GID)
	}
	if err == nil {
		err = f.Chmod(mode)
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = root.Rename(tmp, rel); err != nil {
		return err
	}
	return syncDirectory(root, filepath.Dir(rel))
}

func (m *Manager) Commit(ctx context.Context, changes []Change) error {
	CommitMu.Lock()
	defer CommitMu.Unlock()
	return m.CommitLocked(ctx, changes)
}

// CommitLocked checks every before-version before changing any target. A
// durable undo journal includes application files and their session checkpoint.
// A crash before the commit marker rolls the entire batch back at startup.
func (m *Manager) CommitLocked(ctx context.Context, changes []Change) error {
	if err := CheckReady(); err != nil {
		return err
	}
	if len(changes) == 0 {
		return nil
	}
	if len(changes) > MaxChanges {
		return fmt.Errorf("transaction exceeds %d files", MaxChanges)
	}
	// Reject an oversized supplied batch before allocating fresh disk versions.
	total := 0
	for _, c := range changes {
		if len(c.Before.Data) > MaxFileBytes || len(c.After.Data) > MaxFileBytes {
			return errors.New("transaction file byte budget exceeded")
		}
		total += len(c.Before.Data) + len(c.After.Data)
		if total > MaxTransactionBytes {
			return errors.New("transaction byte budget exceeded")
		}
	}
	if err := m.recoverLocked(); err != nil {
		return m.requireRecovery(err)
	}
	roots := map[string]*os.Root{}
	defer func() {
		for _, root := range roots {
			root.Close()
		}
	}()
	seen := map[string]bool{}
	j := journal{Format: 1}
	total = 0
	for _, c := range changes {
		if err := ctx.Err(); err != nil {
			return err
		}
		canonical, err := filepath.EvalSymlinks(c.Root)
		if err != nil {
			return err
		}
		c.Root = filepath.Clean(canonical)
		if !validPath(c.Path) || !m.allowed(c.Root) {
			return fmt.Errorf("transaction target outside configured roots: %s/%s", c.Root, c.Path)
		}
		id := filepath.Join(c.Root, c.Path)
		if runtime.GOOS == "windows" {
			id = strings.ToLower(id)
		}
		if seen[id] {
			return fmt.Errorf("duplicate transaction target: %s", id)
		}
		seen[id] = true
		root := roots[c.Root]
		if root == nil {
			var err error
			root, err = os.OpenRoot(c.Root)
			if err != nil {
				return err
			}
			roots[c.Root] = root
		}
		current, err := Read(root, c.Path)
		if err != nil {
			return err
		}
		if !same(current, c.Before) {
			return fmt.Errorf("%w: %s", ErrConflict, id)
		}
		c.Before = current
		c.After.UID, c.After.GID = current.UID, current.GID
		if !current.Exists {
			if parent, err := root.Stat(filepath.Dir(c.Path)); err == nil {
				c.After.UID, c.After.GID = ownership(parent)
			}
		}
		total += len(c.Before.Data) + len(c.After.Data)
		if len(c.After.Data) > MaxFileBytes || total > MaxTransactionBytes {
			return errors.New("transaction byte budget exceeded")
		}
		j.Changes = append(j.Changes, c)
	}
	var id string
	if m.Directory != "" {
		id = newID()
		if err := m.writeJournal(id, j); err != nil {
			return err
		}
	}
	applied := 0
	rollback := func(cause error) error {
		if err := restore(j.Changes[:applied], roots); err != nil {
			return m.requireRecovery(fmt.Errorf("%v; recovery journal retained: %w", cause, err))
		}
		if id != "" {
			if err := m.removeJournal(id); err != nil {
				return fmt.Errorf("%v; journal cleanup failed: %w", cause, err)
			}
		}
		return cause
	}
	for i, c := range j.Changes {
		if err := ctx.Err(); err != nil {
			return rollback(err)
		}
		// External programs do not participate in CommitMu. Recheck immediately
		// before each replacement, including after writing the recovery journal.
		current, err := Read(roots[c.Root], c.Path)
		if err != nil {
			return rollback(err)
		}
		if !same(current, c.Before) {
			return rollback(fmt.Errorf("%w: %s", ErrConflict, c.Path))
		}
		applied = i + 1 // a directory-sync error may occur after rename
		if err := Put(roots[c.Root], c.Path, c.After); err != nil {
			return rollback(err)
		}
		if m.afterApply != nil {
			if err := m.afterApply(i); err != nil {
				return err // simulated abrupt process death; retain the journal
			}
		}
	}
	if id != "" {
		if err := m.markCommitted(id); err != nil {
			if errors.Is(err, ErrRecoveryRequired) {
				return m.requireRecovery(err)
			}
			return rollback(err)
		}
		// A durable commit is successful even when cleanup must wait for startup.
		_ = m.removeJournal(id)
	}
	return nil
}

func restore(changes []Change, roots map[string]*os.Root) error {
	// Refuse the entire rollback before touching anything if a third party
	// changed a target. The journal remains for an explicit retry.
	for _, c := range changes {
		current, err := Read(roots[c.Root], c.Path)
		if err != nil {
			return err
		}
		if !same(current, c.Before) && !same(current, c.After) {
			return fmt.Errorf("%w during recovery: %s", ErrConflict, c.Path)
		}
	}
	for i := len(changes) - 1; i >= 0; i-- {
		c := changes[i]
		current, err := Read(roots[c.Root], c.Path)
		if err != nil {
			return err
		}
		if same(current, c.Before) {
			continue
		}
		if !same(current, c.After) {
			return fmt.Errorf("%w during recovery: %s", ErrConflict, c.Path)
		}
		if err := Put(roots[c.Root], c.Path, c.Before); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) writeJournal(id string, j journal) error {
	if err := os.MkdirAll(m.Directory, 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(j)
	if err != nil {
		return err
	}
	defer clear(b)
	stored, err := m.sealRecord("filetxn:journal:"+id, b)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(m.Directory)
	if err != nil {
		return err
	}
	defer root.Close()
	return Put(root, id+".json", State{Exists: true, Data: stored, Mode: 0o600, UID: -1, GID: -1})
}

func (m *Manager) sealRecord(context string, plain []byte) ([]byte, error) {
	if m.protection == nil {
		return plain, nil
	}
	return m.protection.Seal(context, plain)
}

func (m *Manager) openRecord(context string, data []byte) ([]byte, error) {
	if m.protection == nil && !statecrypt.Protected(data) {
		return data, nil
	}
	return m.protection.Open(context, data)
}

func (m *Manager) markCommitted(id string) error {
	root, err := os.OpenRoot(m.Directory)
	if err != nil {
		return err
	}
	defer root.Close()
	marker, err := m.sealRecord("filetxn:commit:"+id, []byte("1"))
	if err != nil {
		return err
	}
	err = Put(root, id+".committed", State{Exists: true, Data: marker, Mode: 0o600, UID: -1, GID: -1})
	if err == nil && m.afterMarker != nil {
		err = m.afterMarker()
	}
	if err != nil {
		remove := m.removeMarker
		if remove == nil {
			remove = func(root *os.Root, path string) error { return root.Remove(path) }
		}
		if removeErr := remove(root, id+".committed"); removeErr != nil && !os.IsNotExist(removeErr) {
			return fmt.Errorf("%w: marker write: %v; removal: %v", ErrRecoveryRequired, err, removeErr)
		}
		// Rolling back while a commit marker can reappear after a crash would
		// let recovery accept a partly rolled-back batch. Removal must be durable.
		if syncErr := m.syncJournalDirectory(root); syncErr != nil {
			return fmt.Errorf("%w: marker removal sync: %v", ErrRecoveryRequired, syncErr)
		}
	}
	return err
}

func (m *Manager) syncJournalDirectory(root *os.Root) error {
	if m.syncJournal != nil {
		return m.syncJournal(root)
	}
	return syncDirectory(root, ".")
}

func (m *Manager) removeJournal(id string) error {
	root, err := os.OpenRoot(m.Directory)
	if err != nil {
		return err
	}
	defer root.Close()
	// Remove the undo record first. A leftover marker alone is harmless.
	if err := root.Remove(id + ".json"); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := m.syncJournalDirectory(root); err != nil {
		return err
	}
	if err := root.Remove(id + ".committed"); err != nil && !os.IsNotExist(err) {
		return err
	}
	return m.syncJournalDirectory(root)
}

func (m *Manager) Recover() error {
	CommitMu.Lock()
	defer CommitMu.Unlock()
	err := m.recoverLocked()
	if err == nil {
		recoveryFaults.Delete(m.Directory)
	} else {
		err = m.requireRecovery(err)
	}
	return err
}

func (m *Manager) recoverLocked() error {
	if m.Directory == "" {
		return nil
	}
	entries, err := os.ReadDir(m.Directory)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, ent := range entries {
		if !strings.HasSuffix(ent.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(ent.Name(), ".json")
		if len(id) != 32 {
			return errors.New("invalid file transaction journal name")
		}
		if _, err := hex.DecodeString(id); err != nil {
			return err
		}
		marker, err := readJournalFile(filepath.Join(m.Directory, id+".committed"), int64(1+statecrypt.Overhead))
		if err == nil {
			value, err := m.openRecord("filetxn:commit:"+id, marker)
			if err != nil || !bytes.Equal(value, []byte("1")) {
				return errors.New("invalid or unreadable file transaction commit marker")
			}
			if _, err := m.loadJournal(id); err != nil {
				return fmt.Errorf("committed transaction %s has an unreadable journal; records preserved: %w", id, err)
			}
			if err := m.removeJournal(id); err != nil {
				return err
			}
			continue
		} else if !os.IsNotExist(err) {
			return err
		}
		if err := m.recoverJournal(id); err != nil {
			return fmt.Errorf("file transaction %s requires recovery: %w", id, err)
		}
	}
	return nil
}

func (m *Manager) loadJournal(id string) (journal, error) {
	var j journal
	stored, err := readJournalFile(filepath.Join(m.Directory, id+".json"), int64(2*MaxTransactionBytes+statecrypt.Overhead))
	if err != nil {
		return j, err
	}
	defer clear(stored)
	data, err := m.openRecord("filetxn:journal:"+id, stored)
	if err != nil {
		return j, err
	}
	defer clear(data)
	if len(data) > 2*MaxTransactionBytes || json.Unmarshal(data, &j) != nil || j.Format != 1 ||
		len(j.Changes) == 0 || len(j.Changes) > MaxChanges {
		return journal{}, errors.New("invalid file transaction journal")
	}
	return j, nil
}

func (m *Manager) recoverJournal(id string) error {
	j, err := m.loadJournal(id)
	if err != nil {
		return err
	}
	roots := map[string]*os.Root{}
	defer func() {
		for _, root := range roots {
			root.Close()
		}
	}()
	total := 0
	for _, c := range j.Changes {
		total += len(c.Before.Data) + len(c.After.Data)
		if !validPath(c.Path) || !m.allowed(c.Root) || total > MaxTransactionBytes ||
			len(c.Before.Data) > MaxFileBytes || len(c.After.Data) > MaxFileBytes {
			return errors.New("invalid file transaction target or byte budget")
		}
		if roots[c.Root] == nil {
			root, err := os.OpenRoot(c.Root)
			if err != nil {
				return err
			}
			roots[c.Root] = root
		}
	}
	if err := restore(j.Changes, roots); err != nil {
		return err
	}
	return m.removeJournal(id)
}

func readJournalFile(path string, limit int64) ([]byte, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > limit {
		return nil, errors.New("invalid file transaction record")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(opened, fi) {
		return nil, errors.New("file transaction record changed during open")
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err == nil && int64(len(b)) > limit {
		return nil, errors.New("file transaction record exceeds its size limit")
	}
	return b, err
}
