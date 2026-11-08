// aurora3-upgradecheck is an unshipped acceptance tool. "fixtures" builds
// agents with a generated public test key and signs them with an in-memory
// private key; no signing private key is written to disk. "run" drives the
// real installed test agent through pinned TLS/yamux and deliberately drops
// the client after handing a job to the independent systemd worker.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"aurora3/internal/entry"
	"aurora3/internal/update"
	"aurora3/internal/upgrade"
	"aurora3/internal/wire"
	"github.com/hashicorp/yamux"
)

func main() {
	var err error
	if len(os.Args) < 3 {
		err = errors.New("usage: upgradecheck fixtures DIR | run DIR")
	} else {
		switch os.Args[1] {
		case "fixtures":
			err = fixtures(os.Args[2])
		case "run":
			err = check(os.Args[2])
		default:
			err = errors.New("unknown command")
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}

func fixtures(out string) error {
	if _, err := os.Stat(out); err == nil {
		return errors.New("fixture output already exists")
	}
	if err := os.MkdirAll(out, 0o700); err != nil {
		return err
	}
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(out, "trust.pub"), []byte(base64.StdEncoding.EncodeToString(pub)), 0o600); err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	publicSource := fmt.Sprintf("package update\nimport \"crypto/ed25519\"\nvar TrustedPublicKeys=[]ed25519.PublicKey{ed25519.PublicKey{%s}}\n", byteLiteral(pub))
	replacement := filepath.Join(out, "test-public.go")
	if err = os.WriteFile(replacement, []byte(publicSource), 0o600); err != nil {
		return err
	}
	overlay, _ := json.Marshal(map[string]any{"Replace": map[string]string{filepath.Join(cwd, "internal", "update", "pubkey.go"): replacement}})
	op := filepath.Join(out, "overlay.json")
	if err = os.WriteFile(op, overlay, 0o600); err != nil {
		return err
	}
	for _, v := range []string{"3.3.0", "3.3.1", "3.3.2", "3.3.3"} {
		bin := filepath.Join(out, "agent-"+v)
		pkg := "./cmd/aurora3-agent"
		if v == "3.3.2" {
			pkg = "./cmd/aurora3-brokenagent"
		}
		cmd := exec.Command("go", "build", "-overlay", op, "-trimpath", "-ldflags", "-s -w -X main.Version="+v, "-o", bin, pkg)
		cmd.Env = append(os.Environ(), "GOOS=linux", "GOARCH=amd64", "CGO_ENABLED=0", "GOTOOLCHAIN=local", "GOPROXY=off")
		if b, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("build %s: %w: %s", v, err, b)
		}
		data, err := os.ReadFile(bin)
		if err != nil {
			return err
		}
		m := update.Manifest{Product: update.ProductAgent, Channel: update.ChannelStable, Version: v, File: "aurora3-agent-" + v + "-linux-amd64", Size: int64(len(data)), SHA256: update.HashBytes(data), Created: time.Now().UTC().Format(time.RFC3339)}
		b, s, err := update.Sign(m, key)
		if err != nil {
			return err
		}
		dir := filepath.Join(out, v)
		if err = os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		if err = os.Rename(bin, filepath.Join(dir, m.File)); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(dir, "manifest.json"), b, 0o600); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(dir, "manifest.sig"), update.SignatureText(s), 0o600); err != nil {
			return err
		}
	}
	for _, name := range []string{"normal", "revoke-current", "revoke-target"} {
		p := update.Policy{Product: update.ProductAgent, Channel: update.ChannelStable, Created: time.Now().UTC().Format(time.RFC3339), MinOK: "3.3.0", Revoked: []string{}}
		if name == "revoke-current" {
			p.Revoked = []string{"3.3.1"}
		}
		if name == "revoke-target" {
			p.Revoked = []string{"3.3.3"}
		}
		b, s, err := update.SignPolicy(p, key)
		if err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(out, name+".json"), b, 0o600); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(out, name+".sig"), update.SignatureText(s), 0o600); err != nil {
			return err
		}
	}
	fmt.Println("fixtures built; signing private key was held only in memory")
	return nil
}

func byteLiteral(b []byte) string {
	parts := make([]string, len(b))
	for i, v := range b {
		parts[i] = fmt.Sprintf("0x%02x", v)
	}
	return strings.Join(parts, ",")
}

type peer struct {
	s    *yamux.Session
	info *wire.AgentInfo
}

func dial(c *entry.Config) (*peer, error) {
	cert, _, err := wire.LoadOrCreateCert(c.StateDir, "agent")
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	raw, err := (&net.Dialer{}).DialContext(ctx, "tcp", "127.0.0.1:17710")
	if err != nil {
		return nil, err
	}
	t := tls.Client(raw, wire.PinnedTLS(wire.CertPin(cert.Certificate[0])))
	_ = t.SetDeadline(time.Now().Add(3 * time.Second))
	if err = wire.WriteJSON(t, wire.Hello{Role: wire.RoleClient, Token: c.Token, Version: wire.Version}); err != nil {
		t.Close()
		return nil, err
	}
	var reply wire.HelloReply
	if err = wire.ReadJSON(t, &reply); err != nil || !reply.OK {
		t.Close()
		return nil, fmt.Errorf("hello: %v %s", err, reply.Error)
	}
	_ = t.SetDeadline(time.Time{})
	s, err := yamux.Client(t, wire.MuxConfig())
	if err != nil {
		t.Close()
		return nil, err
	}
	return &peer{s, reply.Server}, nil
}
func (p *peer) call(op string, args any, out any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return wire.Call(ctx, wire.NewMux(p.s, nil), op, args, out)
}
func waitPeer(c *entry.Config, version string) (*peer, error) {
	until := time.Now().Add(65 * time.Second)
	var last error
	for time.Now().Before(until) {
		p, err := dial(c)
		if err == nil && p.info.Version == version {
			return p, nil
		}
		if p != nil {
			p.s.Close()
		}
		last = err
		time.Sleep(250 * time.Millisecond)
	}
	return nil, fmt.Errorf("version %s did not become healthy: %v", version, last)
}

func request(dir, version, policy string) (upgrade.Request, []byte, error) {
	path := filepath.Join(dir, version)
	mb, err := os.ReadFile(filepath.Join(path, "manifest.json"))
	if err != nil {
		return upgrade.Request{}, nil, err
	}
	sig, err := os.ReadFile(filepath.Join(path, "manifest.sig"))
	if err != nil {
		return upgrade.Request{}, nil, err
	}
	var m update.Manifest
	if err = json.Unmarshal(mb, &m); err != nil {
		return upgrade.Request{}, nil, err
	}
	bin, err := os.ReadFile(filepath.Join(path, m.File))
	if err != nil {
		return upgrade.Request{}, nil, err
	}
	p, err := os.ReadFile(filepath.Join(dir, policy+".json"))
	if err != nil {
		return upgrade.Request{}, nil, err
	}
	ps, err := os.ReadFile(filepath.Join(dir, policy+".sig"))
	if err != nil {
		return upgrade.Request{}, nil, err
	}
	return upgrade.Request{Manifest: mb, Signature: string(sig), Policy: p, PolicySignature: string(ps)}, bin, nil
}

func push(p *peer, req upgrade.Request, data []byte, mutate bool) (string, error) {
	st, err := p.s.OpenStream()
	if err != nil {
		return "", err
	}
	defer st.Close()
	_ = st.SetDeadline(time.Now().Add(80 * time.Second))
	raw, _ := json.Marshal(req)
	if err = wire.WriteJSON(st, wire.Request{Op: "agent.upgrade", Args: raw}); err != nil {
		return "", err
	}
	var res wire.Response
	if err = wire.ReadJSON(st, &res); err != nil {
		return "", err
	}
	if err = res.Err(); err != nil {
		return "", err
	}
	var ready struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(res.Result, &ready)
	if mutate {
		data = append([]byte(nil), data...)
		data[len(data)/2] ^= 1
	}
	for off := 0; off < len(data); off += wire.DataChunk {
		end := min(off+wire.DataChunk, len(data))
		if err = wire.WriteFrame(st, wire.TypeData, data[off:end]); err != nil {
			return ready.ID, err
		}
	}
	if err = wire.WriteFrame(st, wire.TypeEnd, nil); err != nil {
		return ready.ID, err
	}
	// Do not close the yamux stream until the response: half-close support is
	// handled differently by Go's yamux and the native Dart client.
	if err = wire.ReadJSON(st, &res); err != nil {
		return ready.ID, err
	}
	return ready.ID, res.Err()
}

func status(c *entry.Config, id, version, want string) error {
	until := time.Now().Add(100 * time.Second)
	for time.Now().Before(until) {
		p, err := dial(c)
		if err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		var r upgrade.Job
		err = p.call("agent.upgrade.status", map[string]string{"id": id}, &r)
		v := p.info.Version
		p.s.Close()
		if err == nil && (r.State == "upgraded" || r.State == "rolled_back" || r.State == "rollback_failed" || r.State == "refused") {
			if r.State != want || v != version {
				return fmt.Errorf("job state=%s agent=%s want %s/%s: %s", r.State, v, want, version, r.Message)
			}
			fmt.Println("ok job", want, "agent", v)
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return errors.New("upgrade receipt did not complete")
}

func check(dir string) error {
	if runtime.GOOS != "linux" {
		return errors.New("acceptance run requires Linux")
	}
	c, err := entry.LoadConfig(entry.DefaultConfigPath)
	if err != nil {
		return err
	}
	p, err := waitPeer(c, "3.3.0")
	if err != nil {
		return err
	}
	defer p.s.Close()
	if err = p.call("session.create", map[string]any{"name": "upgrade-keep"}, nil); err != nil {
		return err
	}
	// A long-lived process in real tmux must survive both the good switch and
	// the bad candidate's rollback.
	bins, _ := filepath.Glob(filepath.Join(c.StateDir, "bin", "tmux-*"))
	if len(bins) == 0 {
		return errors.New("tmux not unpacked")
	}
	marker := filepath.Join(dir, "surviving.pid")
	if b, err := exec.Command(bins[0], "-L", "aurora3", "send-keys", "-t", "=upgrade-keep:", "sleep 600 & echo $! > "+marker, "Enter").CombinedOutput(); err != nil {
		return fmt.Errorf("start process: %v %s", err, b)
	}
	time.Sleep(time.Second)
	pidBefore, err := os.ReadFile(marker)
	if err != nil {
		return err
	}
	alive := func() error {
		pid := strings.TrimSpace(string(pidBefore))
		if _, err := os.Stat("/proc/" + pid); err != nil {
			return errors.New("terminal job did not survive")
		}
		return nil
	}
	// These refusals happen before independent worker creation.
	for _, tc := range []struct {
		version, policy string
		tamper          bool
	}{{"3.3.3", "revoke-target", false}, {"3.3.1", "normal", true}} {
		r, b, err := request(dir, tc.version, tc.policy)
		if err != nil {
			return err
		}
		if _, err = push(p, r, b, tc.tamper); err == nil {
			return errors.New("unsafe upload was accepted")
		}
		fmt.Println("ok unsafe upload refused", tc.version)
	}
	r, b, err := request(dir, "3.3.1", "normal")
	if err != nil {
		return err
	}
	start := time.Now()
	id, err := push(p, r, b, false)
	if err != nil {
		return err
	}
	if time.Since(start) < 30*time.Second {
		return errors.New("quiet window was skipped")
	}
	p.s.Close()
	fmt.Println("ok client dropped after commit")
	if err = status(c, id, "3.3.1", "upgraded"); err != nil {
		return err
	}
	if err = alive(); err != nil {
		return err
	}
	p, err = waitPeer(c, "3.3.1")
	if err != nil {
		return err
	}
	r, b, err = request(dir, "3.3.2", "normal")
	if err != nil {
		return err
	}
	id, err = push(p, r, b, false)
	if err != nil {
		return err
	}
	p.s.Close()
	if err = status(c, id, "3.3.1", "rolled_back"); err != nil {
		return err
	}
	if err = alive(); err != nil {
		return err
	}
	p, err = waitPeer(c, "3.3.1")
	if err != nil {
		return err
	}
	if _, err = push(p, r, b, false); err == nil {
		return errors.New("failed version retried")
	}
	fmt.Println("ok failed target is blocked")
	r, b, err = request(dir, "3.3.0", "normal")
	if err != nil {
		return err
	}
	if _, err = push(p, r, b, false); err == nil {
		return errors.New("ordinary downgrade accepted")
	}
	fmt.Println("ok ordinary downgrade refused")
	r, b, err = request(dir, "3.3.0", "revoke-current")
	if err != nil {
		return err
	}
	id, err = push(p, r, b, false)
	if err != nil {
		return err
	}
	p.s.Close()
	if err = status(c, id, "3.3.0", "upgraded"); err != nil {
		return err
	}
	if err = alive(); err != nil {
		return err
	}
	fmt.Println("ok safe signed revocation rollback; terminal job survived")
	return nil
}

var _ io.Reader
