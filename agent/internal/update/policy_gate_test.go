package update

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"
)

func TestSignedPolicyAndRevocationRules(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	old := TrustedPublicKeys
	TrustedPublicKeys = []ed25519.PublicKey{pub}
	defer func() { TrustedPublicKeys = old }()
	p := Policy{Product: ProductAgent, Channel: ChannelStable, Created: "2026-11-09T00:00:00Z", Revoked: []string{"3.2.1"}, MinOK: "3.1.0"}
	b, s, err := SignPolicy(p, key)
	if err != nil {
		t.Fatal(err)
	}
	p, err = VerifyPolicy(b, SignatureText(s))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		from, to string
		ok       bool
	}{{"3.1.1", "3.2.2", true}, {"3.2.0", "3.2.1", false}, {"3.2.2", "3.2.0", false}, {"3.2.1", "3.2.0", true}, {"3.2.1", "3.0.0", false}, {"3.2.0", "3.2.0", false}} {
		if err := p.CheckTarget(c.from, c.to); (err == nil) != c.ok {
			t.Errorf("%s -> %s: %v", c.from, c.to, err)
		}
	}
	b[8] ^= 1
	if _, err := VerifyPolicy(b, s); err == nil {
		t.Fatal("tampered policy accepted")
	}
}

func TestTransferGateQuietWindowAndAdmission(t *testing.T) {
	g := &Gate{}
	leave, err := g.Enter()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	if err = g.Seal(ctx, 10*time.Millisecond); err == nil {
		t.Fatal("active transfer ignored")
	}
	cancel()
	leave()
	start := time.Now()
	if err = g.Seal(context.Background(), 40*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) < 40*time.Millisecond {
		t.Fatal("quiet window skipped")
	}
	if _, err = g.Enter(); err == nil {
		t.Fatal("new transfer admitted during commit")
	}
	g.Unseal()
	end, err := g.Enter()
	if err != nil {
		t.Fatal(err)
	}
	end()
}

func TestFailureVersionPersists(t *testing.T) {
	d := t.TempDir()
	if err := RecordFailure(d, Failure{Version: "3.2.1", Message: "health failed"}); err != nil {
		t.Fatal(err)
	}
	bad, err := FailureFor(d, "3.2.1")
	if !bad || err != nil {
		t.Fatal(bad, err)
	}
	bad, err = FailureFor(d, "3.2.2")
	if bad || err != nil {
		t.Fatal(bad, err)
	}
}
