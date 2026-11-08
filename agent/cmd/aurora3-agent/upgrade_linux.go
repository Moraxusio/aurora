//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"aurora3/internal/install"
	"aurora3/internal/update"
	"aurora3/internal/upgrade"
)

func launchUpgrade(dir string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	in, err := os.Open(self)
	if err != nil {
		return err
	}
	defer in.Close()
	worker := filepath.Join(dir, "worker")
	out, err := os.OpenFile(worker, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	cerr := out.Close()
	if err != nil {
		return err
	}
	if cerr != nil {
		return cerr
	}
	return exec.Command("systemd-run", "--quiet", "--collect", "--unit", "aurora3-upgrade-"+filepath.Base(dir), "--property=Type=exec", "--property=RuntimeMaxSec=20min", worker, "upgrade-worker", dir).Run()
}

func upgradeWorker(dir string) (resultErr error) {
	detach()
	defer func() {
		if resultErr == nil {
			return
		}
		var job upgrade.Job
		if b, err := os.ReadFile(filepath.Join(dir, "status.json")); err == nil && json.Unmarshal(b, &job) == nil {
			job.State, job.Message = upgrade.StateRefused, resultErr.Error()
			_ = upgrade.WriteJob(dir, job)
		}
	}()
	b, err := os.ReadFile(filepath.Join(dir, "request.json"))
	if err != nil {
		return err
	}
	var req upgrade.Request
	if err = json.Unmarshal(b, &req); err != nil {
		return err
	}
	m, err := update.VerifyFor(update.ProductAgent, update.ChannelStable, req.Manifest, []byte(req.Signature))
	if err != nil {
		return err
	}
	p, err := update.VerifyPolicy(req.Policy, []byte(req.PolicySignature))
	if err != nil {
		return err
	}
	var j upgrade.Job
	jb, err := os.ReadFile(filepath.Join(dir, "status.json"))
	if err != nil {
		return err
	}
	if err = json.Unmarshal(jb, &j); err != nil {
		return err
	}
	fail := func(err error) error {
		j.State = "refused"
		j.Message = err.Error()
		_ = upgrade.WriteJob(dir, j)
		return err
	}
	if err = p.CheckTarget(j.Previous, m.Version); err != nil {
		return fail(err)
	}
	bin := filepath.Join(dir, "agent")
	f, err := os.Open(bin)
	if err != nil {
		return fail(err)
	}
	h := sha256.New()
	size, err := io.Copy(h, f)
	f.Close()
	if err != nil {
		return fail(err)
	}
	if size != m.Size || hex.EncodeToString(h.Sum(nil)) != m.SHA256 {
		return fail(errors.New("候选 agent 校验失败"))
	}
	if err = os.WriteFile(filepath.Join(dir, "policy.json"), req.Policy, 0o600); err != nil {
		return fail(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "policy.sig"), []byte(req.PolicySignature), 0o600); err != nil {
		return fail(err)
	}
	j.State = "installing"
	_ = upgrade.WriteJob(dir, j)
	// Use the current trusted install engine, with the verified candidate as
	// Self. A safe rollback target may predate --policy or upgrade-worker and
	// must not be expected to understand the new control protocol.
	var privateOutput bytes.Buffer
	env := env()
	env.Self, env.Version, env.Out = bin, m.Version, &privateOutput
	result := install.Run(env, install.Options{SHA256: m.SHA256, Policy: &p})
	j.State = result.Result
	j.Message = result.Message
	if err = upgrade.WriteJob(dir, j); err != nil {
		return err
	}
	_ = os.Remove(bin)
	_ = os.Remove(filepath.Join(dir, "worker"))
	_ = os.Remove(filepath.Join(dir, "request.json"))
	_ = os.Remove(filepath.Join(dir, "policy.json"))
	_ = os.Remove(filepath.Join(dir, "policy.sig"))
	return nil
}
