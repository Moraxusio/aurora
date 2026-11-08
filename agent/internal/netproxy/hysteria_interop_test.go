package netproxy

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aurora3/internal/wire"
)

// Hysteria2 against the project's own released server binary. Set
// AURORA3_HYSTERIA to its path to run these; they are skipped otherwise. The
// binary only serves the tests and is not shipped.
func hysteriaBin(t *testing.T) string {
	t.Helper()
	p := os.Getenv("AURORA3_HYSTERIA")
	if p == "" {
		t.Skip("AURORA3_HYSTERIA is not set")
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("no hysteria at %s", p)
	}
	return p
}

func startHysteriaServer(t *testing.T, bin, password, obfs string) (addr, pin string) {
	t.Helper()
	dir := t.TempDir()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "node.example"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour), DNSNames: []string{"node.example"},
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := x509.MarshalECPrivateKey(key)
	crt, keyf := filepath.Join(dir, "c.crt"), filepath.Join(dir, "c.key")
	_ = os.WriteFile(crt, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)
	_ = os.WriteFile(keyf, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600)

	pc, _ := net.ListenPacket("udp", "127.0.0.1:0")
	port := pc.LocalAddr().(*net.UDPAddr).Port
	pc.Close()
	y := "listen: 127.0.0.1:" + itoa(port) + "\n" +
		"tls:\n  cert: " + filepath.ToSlash(crt) + "\n  key: " + filepath.ToSlash(keyf) + "\n" +
		"auth:\n  type: password\n  password: " + password + "\n" +
		"outbounds:\n  - name: direct\n    type: direct\n"
	if obfs != "" {
		y += "obfs:\n  type: salamander\n  salamander:\n    password: " + obfs + "\n"
	}
	cfg := filepath.Join(dir, "s.yaml")
	_ = os.WriteFile(cfg, []byte(y), 0o600)
	cmd := exec.Command(bin, "server", "-c", cfg)
	var out strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if t.Failed() {
			t.Logf("hysteria said:\n%s", out.String())
		}
	})
	time.Sleep(600 * time.Millisecond)
	return "127.0.0.1:" + itoa(port), wire.CertPin(der)
}

func TestHysteriaProjectServer(t *testing.T) {
	bin := hysteriaBin(t)
	echo := echoServer(t)
	addr, pin := startHysteriaServer(t, bin, "correct-horse-battery", "")
	d, err := newDialer(hy2Node(addr, pin, "correct-horse-battery"), 5*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	echoThrough(t, d, echo, "against the real server")
}

func TestHysteriaProjectServerWithSalamander(t *testing.T) {
	bin := hysteriaBin(t)
	echo := echoServer(t)
	addr, pin := startHysteriaServer(t, bin, "correct-horse-battery", "obfs-secret-1")
	n := hy2Node(addr, pin, "correct-horse-battery")
	n.Obfs, n.ObfsPassword = "salamander", "obfs-secret-1"
	d, err := newDialer(n, 5*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	echoThrough(t, d, echo, "salamander against the real server")
}
