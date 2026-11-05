package update

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"strings"
	"testing"
)

func testManifest() Manifest {
	return Manifest{Product: "aurora-desktop", Channel: "stable", Version: "2.0.0+20261103101907", File: "x.exe", Size: 0, SHA256: "0000000000000000000000000000000000000000000000000000000000000000", Created: "now"}
}
func TestSignVerifyAndTamper(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	m := testManifest()
	m.KeyID = KeyID(pub) // Sign fills this in; see TestSignSetsKeyID
	b, s, e := Sign(m, priv)
	if e != nil {
		t.Fatal(e)
	}
	got, e := Verify(b, s, pub)
	if e != nil || got != m {
		t.Fatalf("verify: %v", e)
	}
	b[0] ^= 1
	if _, e = Verify(b, s, pub); e == nil {
		t.Fatal("tampered manifest accepted")
	}
	b, s, _ = Sign(m, priv)
	s[0] ^= 1
	if _, e = Verify(b, s, pub); e == nil {
		t.Fatal("tampered signature accepted")
	}
}
func TestVerifyTrustedSecondKey(t *testing.T) {
	_, p1, _ := ed25519.GenerateKey(rand.Reader)
	pub2, p2, _ := ed25519.GenerateKey(rand.Reader)
	b, s, _ := Sign(testManifest(), p2)
	old := TrustedPublicKeys
	t.Cleanup(func() { TrustedPublicKeys = old })
	TrustedPublicKeys = []ed25519.PublicKey{p1.Public().(ed25519.PublicKey), pub2}
	if _, e := VerifyTrusted(b, s); e != nil {
		t.Fatal(e)
	}
}
func TestValidateEdges(t *testing.T) {
	for _, m := range []Manifest{{Product: "bad/", Channel: "stable"}, {Product: "aurora", Channel: "bad/"}, {Product: "aurora", Channel: "stable", SHA256: "bad"}, {Product: "aurora", Channel: "stable", Size: -1}, {Product: "aurora", Channel: "stable", Size: MaxFileSize + 1}} {
		m.Version = "1"
		m.File = "x"
		m.Created = "x"
		if e := Validate(m); e == nil {
			t.Fatalf("accepted %#v", m)
		}
	}
}
func TestCompareVersion(t *testing.T) {
	for _, x := range []struct {
		a, b string
		want int
	}{{"2.0.0+20261103101907", "2.0.0+20261104000000", -1}, {"2.1.0", "2.0.9+20991231000000", 1}, {"2.0.0", "2.0.0", 0}, {"2.0.0", "2.0.0+1", -1}} {
		if got := CompareVersion(x.a, x.b); got != x.want {
			t.Errorf("%s %s: %d", x.a, x.b, got)
		}
	}
}

func TestSignSetsKeyID(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	b, s, err := Sign(testManifest(), priv)
	if err != nil {
		t.Fatal(err)
	}
	m, err := Verify(b, s, pub)
	if err != nil {
		t.Fatal(err)
	}
	if m.KeyID != KeyID(pub) {
		t.Fatalf("key id %q, want %q", m.KeyID, KeyID(pub))
	}
}

// A manifest that names a key other than the one that signed it is refused,
// even though the signature itself is valid for the other key.
func TestVerifyRejectsKeyIDMismatch(t *testing.T) {
	pubA, privA, _ := ed25519.GenerateKey(rand.Reader)
	pubB, _, _ := ed25519.GenerateKey(rand.Reader)
	m := testManifest()
	m.KeyID = KeyID(pubB)
	b, s, err := Sign(m, privA)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Verify(b, s, pubA); err == nil {
		t.Fatal("a manifest claiming another key id was accepted")
	}
}

// The id picks the key: an untrusted id fails with that reason, and an unset id
// (an old manifest) still verifies against every trusted key.
func TestVerifyTrustedUsesTheKeyID(t *testing.T) {
	pubA, privA, _ := ed25519.GenerateKey(rand.Reader)
	_, privB, _ := ed25519.GenerateKey(rand.Reader)
	old := TrustedPublicKeys
	t.Cleanup(func() { TrustedPublicKeys = old })
	TrustedPublicKeys = []ed25519.PublicKey{pubA}

	b, s, _ := Sign(testManifest(), privB)
	if _, err := VerifyTrusted(b, s); err == nil || !strings.Contains(err.Error(), "does not trust") {
		t.Fatalf("untrusted key id: %v", err)
	}

	// A legacy manifest with no key id is still accepted by any trusted key.
	m := testManifest()
	raw, _ := json.Marshal(m)
	sig := ed25519.Sign(privA, raw)
	if _, err := VerifyTrusted(raw, SignatureText(sig)); err != nil {
		t.Fatalf("legacy manifest: %v", err)
	}
}
