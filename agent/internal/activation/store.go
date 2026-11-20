//go:build linux || windows

// Package activation manages a single durable program selection record.
// It owns no user state and must not be used to trial a migrator against
// the active version's writable state.
package activation

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"aurora3/internal/statecrypt"
	"aurora3/internal/update"
)

const selectionName = "selection.json"

type Program struct {
	Version string `json:"version"`
	SHA256  string `json:"sha256"`
}

type Receipt struct {
	ID     string  `json:"id"`
	Target Program `json:"target"`
	State  string  `json:"state"`
}

type Selection struct {
	Format   int      `json:"format"`
	Active   Program  `json:"active"`
	Previous *Program `json:"previous,omitempty"`
	Receipt  *Receipt `json:"receipt,omitempty"`
}

// Verify must check the exact program bytes and signed policy on every call.
// It must not run the program or perform state migrations.
type Verify func(Program) error

type Store struct {
	Dir    string
	Verify Verify
	save   func(stage, final string) error // private fault injection
}

var digestRE = regexp.MustCompile(`^[0-9a-f]{64}$`)
var receiptRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

func valid(p Program) bool {
	_, _, err := update.ParseVersionStrict(p.Version)
	return err == nil && digestRE.MatchString(p.SHA256)
}

func (s *Store) read() (Selection, error) {
	root, err := statecrypt.OpenStateDir(s.Dir)
	if err != nil {
		return Selection{}, err
	}
	defer root.Close()
	b, err := statecrypt.ReadRegular(root, selectionName, 4096)
	if err != nil {
		return Selection{}, err
	}
	var r Selection
	if err := json.Unmarshal(b, &r); err != nil || r.Format != 1 || !valid(r.Active) {
		return Selection{}, errors.New("版本选择记录损坏；拒绝猜测可启动版本")
	}
	if r.Previous != nil && (!valid(*r.Previous) || r.Previous.Version == r.Active.Version) {
		return Selection{}, errors.New("上一版本记录损坏")
	}
	if receipt := r.Receipt; receipt != nil {
		if !receiptRE.MatchString(receipt.ID) || !valid(receipt.Target) {
			return Selection{}, errors.New("版本收据损坏")
		}
		switch receipt.State {
		case "confirmed":
			if receipt.Target != r.Active {
				return Selection{}, errors.New("已确认收据与当前版本不符")
			}
		case "trying", "abandoned":
			if receipt.Target.Version == r.Active.Version ||
				(r.Previous != nil && receipt.Target.Version == r.Previous.Version && receipt.Target != *r.Previous) {
				return Selection{}, errors.New("试运行收据冲突")
			}
		default:
			return Selection{}, errors.New("未知版本收据状态")
		}
	}
	return r, nil
}

func (s *Store) write(r Selection) error {
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(s.Dir, ".selection-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(b)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	publish := s.save
	if publish == nil {
		publish = statecrypt.ReplaceFile
	}
	return publish(f.Name(), filepath.Join(s.Dir, selectionName))
}

func (s *Store) lock() (func(), error) {
	if s.Verify == nil {
		return nil, errors.New("缺少程序验签和撤回策略")
	}
	return statecrypt.LockWriter(s.Dir)
}

func (s *Store) Initialize(active Program) error {
	return s.InitializeReady(active, nil)
}

func (s *Store) InitializeReady(active Program, ready func(Program) error) error {
	unlock, err := s.lock()
	if err != nil {
		return err
	}
	defer unlock()
	if _, err := s.read(); !os.IsNotExist(err) {
		return errors.New("版本选择已存在或无法读取；不会初始化覆盖")
	}
	if err := statecrypt.CheckNewDir(s.Dir); err != nil {
		return err
	}
	if !valid(active) {
		return errors.New("无效的初始版本")
	}
	if err := s.Verify(active); err != nil {
		return err
	}
	if ready != nil {
		if err := ready(active); err != nil {
			return err
		}
		if err := s.Verify(active); err != nil {
			return err
		}
	}
	return s.write(Selection{Format: 1, Active: active})
}

// ReadReceipt never replays an install, trial or commit on a lost response.
func (s *Store) ReadReceipt() (Selection, error) { return s.read() }

// Trial holds exclusive program selection through the readiness callback.
// The callback must use an isolated state generation and must not leave its
// trial process running. Only the final pointer write changes Active.
func (s *Store) Trial(expected, target Program, ready func(Program) error) (Receipt, error) {
	unlock, err := s.lock()
	if err != nil {
		return Receipt{}, err
	}
	defer unlock()
	r, err := s.read()
	if err != nil {
		return Receipt{}, err
	}
	if !valid(target) || ready == nil || r.Active != expected ||
		(r.Receipt != nil && r.Receipt.State == "trying") {
		return Receipt{}, errors.New("当前选择已变化、存在未决试运行，或候选/确认无效")
	}
	if r.Receipt != nil && r.Receipt.Target.Version == target.Version {
		return Receipt{}, errors.New("已有该版本试运行收据；查询原收据，不重放同版本切换")
	}
	// A manual downgrade and a revoked-version emergency require their own
	// state-compatibility proof, not a replay of this forward-only operation.
	cmp, err := update.CompareVersionStrict(target.Version, r.Active.Version)
	if err != nil || cmp <= 0 {
		return Receipt{}, errors.New("试运行只接受不同且更高的版本")
	}
	for _, p := range []Program{r.Active, target} {
		if err := s.Verify(p); err != nil {
			return Receipt{}, err
		}
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return Receipt{}, err
	}
	job := Receipt{ID: hex.EncodeToString(nonce[:]), Target: target, State: "trying"}
	r.Receipt = &job
	if err := s.write(r); err != nil {
		return job, err
	}
	if err := ready(target); err != nil {
		job.State = "abandoned"
		if persist := s.write(r); persist != nil {
			return job, errors.Join(err, persist)
		}
		return job, err
	}
	if err := s.Verify(target); err != nil {
		return job, err // boot recovery will abandon the tentative receipt
	}
	previous := r.Active
	r.Active, r.Previous, job.State = target, &previous, "confirmed"
	if err := s.write(r); err != nil {
		// The rename might already have taken effect. Query, never retry.
		return job, fmt.Errorf("选择提交结果未知，请查询收据 %s：%w", job.ID, err)
	}
	return job, nil
}

// SelectOnBoot never starts an unconfirmed candidate. A damaged or revoked
// active program blocks startup; selecting an older compatible state
// generation is an explicit operation, not an unverified fallback.
func (s *Store) SelectOnBoot() (Program, error) {
	unlock, err := s.lock()
	if err != nil {
		return Program{}, err
	}
	defer unlock()
	r, err := s.read()
	if err != nil {
		return Program{}, err
	}
	if err := s.Verify(r.Active); err != nil {
		return Program{}, err
	}
	if r.Receipt != nil && r.Receipt.State == "trying" {
		r.Receipt.State = "abandoned"
		if err := s.write(r); err != nil {
			return Program{}, err
		}
	}
	return r.Active, nil
}
