package update

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"
)

// useTestKey trusts one generated key for the test and restores the old list.
func useTestKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	old := TrustedPublicKeys
	t.Cleanup(func() { TrustedPublicKeys = old })
	TrustedPublicKeys = []ed25519.PublicKey{pub}
	return priv
}

func productManifest(product, channel string) Manifest {
	return Manifest{Product: product, Channel: channel, Version: "2.0.1+20261105010203", File: "aurora-agent-2.0.1+20261105010203", Size: 4, SHA256: strings.Repeat("a", 64), Created: "2026-11-05T01:02:03Z"}
}

func TestVerifyForAcceptsMatchingProductAndChannel(t *testing.T) {
	priv := useTestKey(t)
	mb, sig, err := Sign(productManifest(ProductAgent, ChannelStable), priv)
	if err != nil {
		t.Fatal(err)
	}
	m, err := VerifyFor(ProductAgent, ChannelStable, mb, sig)
	if err != nil || m.Product != ProductAgent || m.Channel != ChannelStable {
		t.Fatalf("matching manifest rejected: %+v %v", m, err)
	}
}

func TestVerifyForProductMismatch(t *testing.T) {
	priv := useTestKey(t)
	mb, sig, _ := Sign(testManifest(), priv) // signed aurora-desktop manifest
	m, err := VerifyFor(ProductAgent, ChannelStable, mb, sig)
	if err == nil {
		t.Fatal("desktop manifest accepted as aurora-agent")
	}
	if !strings.Contains(err.Error(), "product") || !strings.Contains(err.Error(), ProductAgent) {
		t.Fatalf("error does not name the product mismatch: %v", err)
	}
	if m != (Manifest{}) {
		t.Fatalf("mismatch returned a manifest: %+v", m)
	}
}

func TestVerifyForChannelMismatch(t *testing.T) {
	priv := useTestKey(t)
	mb, sig, _ := Sign(productManifest(ProductRelay, "beta"), priv)
	m, err := VerifyFor(ProductRelay, ChannelStable, mb, sig)
	if err == nil || !strings.Contains(err.Error(), "channel") {
		t.Fatalf("channel mismatch not reported: %v", err)
	}
	if m != (Manifest{}) {
		t.Fatalf("mismatch returned a manifest: %+v", m)
	}
}

func TestVerifyForFlippedManifestByte(t *testing.T) {
	priv := useTestKey(t)
	mb, sig, _ := Sign(productManifest(ProductAgent, ChannelStable), priv)
	mb[len(mb)/2] ^= 1
	if _, err := VerifyFor(ProductAgent, ChannelStable, mb, sig); err == nil {
		t.Fatal("flipped manifest byte accepted")
	}
}

func TestVerifyForFlippedSignatureByte(t *testing.T) {
	priv := useTestKey(t)
	mb, sig, _ := Sign(productManifest(ProductAgent, ChannelStable), priv)
	sig[0] ^= 1
	if _, err := VerifyFor(ProductAgent, ChannelStable, mb, sig); err == nil {
		t.Fatal("flipped signature byte accepted")
	}
}

func TestVerifyForTruncatedSignature(t *testing.T) {
	priv := useTestKey(t)
	mb, sig, _ := Sign(productManifest(ProductAgent, ChannelStable), priv)
	for _, cut := range [][]byte{sig[:len(sig)-1], sig[:1], nil} {
		if _, err := VerifyFor(ProductAgent, ChannelStable, mb, cut); err == nil {
			t.Fatalf("truncated signature (%d bytes) accepted", len(cut))
		}
	}
	// The same check in the text form, which is what the store keeps on disk.
	text := SignatureText(sig)
	if _, err := VerifyFor(ProductAgent, ChannelStable, mb, text[:len(text)-10]); err == nil {
		t.Fatal("truncated text signature accepted")
	}
}

func TestVerifyForUnknownKey(t *testing.T) {
	useTestKey(t)
	other := useOtherKey(t)
	mb, sig, _ := Sign(productManifest(ProductAgent, ChannelStable), other)
	if _, err := VerifyFor(ProductAgent, ChannelStable, mb, sig); err == nil {
		t.Fatal("manifest signed by an unknown key accepted")
	}
}

// useOtherKey returns a private key that is not in TrustedPublicKeys.
func useOtherKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func TestCompareVersionStrictEqualAndOlder(t *testing.T) {
	for _, x := range []struct {
		a, b string
		want int
	}{
		{"2.0.0+20261104163215", "2.0.0+20261104163215", 0},
		{"2.0.0", "2.0.0", 0},
		{"2.0.0+20261103101907", "2.0.0+20261104000000", -1},
		{"2.0.0+20261104000000", "2.0.0+20261103101907", 1},
		{"2.0.0", "2.0.0+1", -1},
		{"1.9.9+99999999999999", "2.0.0", -1},
		{"2.1.0", "2.0.9+20991231000000", 1},
	} {
		got, err := CompareVersionStrict(x.a, x.b)
		if err != nil || got != x.want {
			t.Errorf("CompareVersionStrict(%q, %q) = %d, %v; want %d", x.a, x.b, got, err, x.want)
		}
	}
}

func TestCompareVersionStrictRejectsMalformed(t *testing.T) {
	for _, bad := range []string{"", "2.0", "2.0.0.1", "v2.0.0", "2.0.0-dev", "2.0.0+", "2.0.0+abc", "2.00.0", "2.0.0+1234567890123456789", "2.0.0 ", "99999999999999999999.0.0", "2.0.0+20261104163215+1"} {
		if _, err := CompareVersionStrict(bad, "2.0.0"); err == nil {
			t.Errorf("malformed %q accepted as first argument", bad)
		}
		if _, err := CompareVersionStrict("2.0.0", bad); err == nil {
			t.Errorf("malformed %q accepted as second argument", bad)
		}
	}
}

func TestCompareVersionUnchangedForDesktop(t *testing.T) {
	// The desktop client keeps the lenient comparison, so "-dev" still reads as 0.
	if got := CompareVersion("2.0.0-dev", "2.0.0"); got != 0 {
		t.Fatalf("CompareVersion changed: %d", got)
	}
}
