// Package upgrade accepts signed binaries over the existing authenticated
// link. It never replaces the running file itself: a separate worker performs
// the proven four-stage install, outside the agent's systemd cgroup.
package upgrade

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"aurora3/internal/service"
	"aurora3/internal/update"
	"aurora3/internal/wire"
)

type Request struct {
	Manifest        []byte `json:"manifest"`
	Signature       string `json:"signature"`
	Policy          []byte `json:"policy"`
	PolicySignature string `json:"policy_signature"`
}
type Job struct {
	ID       string `json:"id"`
	Version  string `json:"version"`
	State    string `json:"state"`
	Message  string `json:"message,omitempty"`
	Previous string `json:"previous,omitempty"`
}

const (
	StateUploading      = "uploading"
	StateWaiting        = "waiting"
	StateStarting       = "starting"
	StateInstalling     = "installing"
	StateInstalled      = "installed"
	StateUpgraded       = "upgraded"
	StateUpToDate       = "up_to_date"
	StateRolledBack     = "rolled_back"
	StateRollbackFailed = "rollback_failed"
	StateRefused        = "refused"
	StateFailed         = "failed"
)

var idRE = regexp.MustCompile(`^[0-9a-f]{24}$`)

func terminalState(state string) bool {
	switch state {
	case StateInstalled, StateUpgraded, StateUpToDate, StateRolledBack, StateRollbackFailed, StateRefused, StateFailed:
		return true
	default:
		return false
	}
}

type Env struct {
	StateDir, Version, Arch string
	Gate                    *update.Gate
	Quiet, MaxWait          time.Duration
	// WorkerWait bounds an accepted task whose independent worker never writes
	// a terminal result. It is configurable in tests; production defaults to
	// twenty minutes and systemd applies the same runtime cap.
	WorkerWait time.Duration
	Launch     func(dir string) error
	mu         sync.Mutex
	busy       bool
}

func (e *Env) Operations() []service.Operation {
	return []service.Operation{{Name: "agent.upgrade", Stream: e.upload}, {Name: "agent.upgrade.status", Handle: e.status}}
}
func (e *Env) status(_ context.Context, raw json.RawMessage) (any, error) {
	var a struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, wire.Errf(wire.CodeBadRequest, "参数格式错误")
	}
	if !idRE.MatchString(a.ID) {
		return nil, wire.Errf(wire.CodeBadRequest, "升级任务编号无效")
	}
	dir := filepath.Join(e.StateDir, "upgrades", a.ID)
	j, err := e.expireJob(dir)
	if err != nil {
		return nil, wire.Errf(wire.CodeNotFound, "找不到升级任务")
	}
	return j, nil
}

func (e *Env) workerWait() time.Duration {
	if e.WorkerWait > 0 {
		return e.WorkerWait
	}
	return 20 * time.Minute
}

// expireJob converts a task abandoned by a crashed/expired worker into a
// durable result. Uploading/waiting is retryable because no install was
// committed; starting/installing is recorded as a failed target so a client
// cannot blindly push the same candidate again.
func (e *Env) expireJob(dir string) (Job, error) {
	b, err := os.ReadFile(filepath.Join(dir, "status.json"))
	if err != nil {
		return Job{}, err
	}
	var j Job
	if err = json.Unmarshal(b, &j); err != nil {
		return Job{}, err
	}
	if terminalState(j.State) {
		return j, nil
	}
	info, err := os.Stat(filepath.Join(dir, "status.json"))
	if err != nil || time.Since(info.ModTime()) <= e.workerWait() {
		return j, nil
	}
	old := j.State
	j.State = StateFailed
	j.Message = "独立升级进程超时或没有返回结果；没有自动重复推送"
	if err = WriteJob(dir, j); err != nil {
		return Job{}, err
	}
	if old == StateStarting || old == StateInstalling {
		_ = update.RecordFailure(e.StateDir, update.Failure{Version: j.Version, Message: j.Message})
	}
	return j, nil
}

func WriteJob(dir string, j Job) error {
	b, err := json.Marshal(j)
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, "status.tmp")
	if err = os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, "status.json"))
}

func (e *Env) upload(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	var a Request
	if err := json.Unmarshal(raw, &a); err != nil {
		return wire.Errf(wire.CodeBadRequest, "升级请求格式错误")
	}
	m, err := update.VerifyFor(update.ProductAgent, update.ChannelStable, a.Manifest, []byte(a.Signature))
	if err != nil {
		return wire.Errf(wire.CodeForbidden, "签名验证失败：%v", err)
	}
	p, err := update.VerifyPolicy(a.Policy, []byte(a.PolicySignature))
	if err != nil {
		return wire.Errf(wire.CodeForbidden, "%v", err)
	}
	if err = p.CheckTarget(e.Version, m.Version); err != nil {
		return wire.Errf(wire.CodeConflict, "%v", err)
	}
	if m.MinFrom != "" {
		if cmp, err := update.CompareVersionStrict(e.Version, m.MinFrom); err != nil || cmp < 0 {
			return wire.Errf(wire.CodeConflict, "当前版本低于此构建的最低升级来源")
		}
	}
	if bad, err := update.FailureFor(e.StateDir, m.Version); err != nil {
		return wire.Errf(wire.CodeInternal, "读取失败版本记录失败")
	} else if bad {
		return wire.Errf(wire.CodeConflict, "目标版本曾升级失败，拒绝重复推送")
	}
	if m.File != fmt.Sprintf("aurora3-agent-%s-linux-%s", m.Version, e.Arch) || m.Size <= 0 || m.Size > 128<<20 {
		return wire.Errf(wire.CodeBadRequest, "升级文件的架构或大小无效")
	}
	e.mu.Lock()
	if e.busy {
		e.mu.Unlock()
		return wire.Errf(wire.CodeConflict, "已有升级任务")
	}
	e.busy = true
	e.mu.Unlock()
	keep := false
	defer func() {
		if !keep {
			e.mu.Lock()
			e.busy = false
			e.mu.Unlock()
		}
	}()
	// A worker may outlive the old agent. A fresh agent must not accept a
	// second job merely because its in-memory mutex started empty.
	entries, _ := os.ReadDir(filepath.Join(e.StateDir, "upgrades"))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		j, err := e.expireJob(filepath.Join(e.StateDir, "upgrades", entry.Name()))
		if err != nil {
			continue
		}
		if j.State == StateUploading || j.State == StateWaiting || j.State == StateStarting || j.State == StateInstalling {
			return wire.Errf(wire.CodeConflict, "仍有独立升级任务在运行，请先查询结果")
		}
	}
	// A stale starting/installing task may have just recorded its target in
	// failed-upgrades.json. Recheck after expiry before accepting this request;
	// otherwise the same candidate could slip through the first check above.
	if bad, err := update.FailureFor(e.StateDir, m.Version); err != nil {
		return wire.Errf(wire.CodeInternal, "读取失败版本记录失败")
	} else if bad {
		return wire.Errf(wire.CodeConflict, "目标版本曾升级失败，拒绝重复推送")
	}
	id := wire.NewToken()[:24]
	dir := filepath.Join(e.StateDir, "upgrades", id)
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	defer func() {
		if !keep {
			_ = os.RemoveAll(dir)
		}
	}()
	if err = os.WriteFile(filepath.Join(dir, "request.json"), raw, 0o600); err != nil {
		return err
	}
	if err = WriteJob(dir, Job{ID: id, Version: m.Version, Previous: e.Version, State: StateUploading}); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(dir, "agent"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
	if err != nil {
		return err
	}
	defer f.Close()
	if err = wire.WriteJSON(st, wire.OKResponse(map[string]any{"ready": true, "id": id})); err != nil {
		return err
	}
	h := sha256.New()
	var size int64
	for {
		_ = st.SetReadDeadline(time.Now().Add(2 * time.Minute))
		typ, b, readErr := wire.ReadFrame(st)
		if readErr != nil {
			return readErr
		}
		if typ == wire.TypeEnd {
			break
		}
		if typ != wire.TypeData {
			return errors.New("升级数据帧无效")
		}
		size += int64(len(b))
		if size > m.Size {
			return errors.New("升级文件超过签名大小")
		}
		if _, err = io.MultiWriter(f, h).Write(b); err != nil {
			return err
		}
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if size != m.Size || hex.EncodeToString(h.Sum(nil)) != m.SHA256 {
		return wire.Errf(wire.CodeForbidden, "升级文件的哈希或大小不符")
	}
	if err = WriteJob(dir, Job{ID: id, Version: m.Version, Previous: e.Version, State: StateWaiting}); err != nil {
		return err
	}
	quiet, maxWait := e.Quiet, e.MaxWait
	if quiet <= 0 {
		quiet = 30 * time.Second
	}
	if maxWait <= 0 {
		maxWait = 15 * time.Minute
	}
	wait, cancel := context.WithTimeout(ctx, maxWait)
	defer cancel()
	if e.Gate != nil {
		if err = e.Gate.Seal(wait, quiet); err != nil {
			return wire.Errf(wire.CodeConflict, "等待文件传输结束超时，未升级")
		}
		defer func() {
			if !keep {
				e.Gate.Unseal()
			}
		}()
	}
	j := Job{ID: id, Version: m.Version, Previous: e.Version, State: StateStarting}
	if err = WriteJob(dir, j); err != nil {
		return err
	}
	if e.Launch == nil {
		return wire.Errf(wire.CodeUnavailable, "此 agent 未启用升级执行器")
	}
	if err = e.Launch(dir); err != nil {
		return wire.Errf(wire.CodeUnavailable, "启动独立升级进程失败：%v", err)
	}
	keep = true
	go e.watch(dir)
	return wire.WriteJSON(st, wire.OKResponse(j))
}
func (e *Env) watch(dir string) {
	deadline := time.Now().Add(20 * time.Minute)
	for time.Now().Before(deadline) {
		if j, err := e.expireJob(dir); err == nil && terminalState(j.State) {
			break
		}
		time.Sleep(time.Second)
	}
	if e.Gate != nil {
		e.Gate.Unseal()
	}
	e.mu.Lock()
	e.busy = false
	e.mu.Unlock()
}
