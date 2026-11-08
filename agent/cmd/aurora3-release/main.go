// aurora3-release signs agent builds for the client to bundle (D-3, D-13).
// The private key never leaves the build machine; the client verifies with
// the public key it carries (update.TrustedPublicKeys and its Dart copy).
//
//	aurora3-release pubkey --key PATH
//	aurora3-release sign --key PATH --product aurora3-agent --channel stable \
//	    --version V --arch amd64 --file BIN --out DIR
//	aurora3-release verify --product aurora3-agent --channel stable --dir DIR
//
// sign writes DIR/manifest.json, DIR/manifest.sig and a copy of the file
// named in the manifest. Tests sign with a generated key (--key of a test
// key file) and trust it with --trust.
package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"aurora3/internal/update"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "pubkey":
		err = pubkeyCmd(os.Args[2:], os.Stdout)
	case "sign":
		err = signCmd(os.Args[2:], os.Stdout)
	case "verify":
		err = verifyCmd(os.Args[2:], os.Stdout)
	case "policy":
		err = policyCmd(os.Args[2:], os.Stdout)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "aurora3-release:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: aurora3-release pubkey --key PATH | sign --key PATH --product P --channel C --version V --arch A --file BIN --out DIR | verify --product P --channel C --dir DIR [--trust PUBKEY_B64]")
	os.Exit(2)
}

// readKey reads a base64 ed25519 private key (64 bytes) from path.
func readKey(path string) (ed25519.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	kb, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(kb) != ed25519.PrivateKeySize {
		return nil, errors.New("invalid private key file")
	}
	return ed25519.PrivateKey(kb), nil
}

func pubkeyCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("pubkey", flag.ContinueOnError)
	key := fs.String("key", "", "private key file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	priv, err := readKey(*key)
	if err != nil {
		return err
	}
	pub := priv.Public().(ed25519.PublicKey)
	_, err = fmt.Fprintf(out, "%s\n%s\n", base64.StdEncoding.EncodeToString(pub), update.KeyID(pub))
	return err
}

func signCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("sign", flag.ContinueOnError)
	key := fs.String("key", "", "private key file")
	product := fs.String("product", update.ProductAgent, "product")
	channel := fs.String("channel", update.ChannelStable, "channel")
	version := fs.String("version", "", "version (MAJOR.MINOR.PATCH)")
	arch := fs.String("arch", "", "linux architecture: amd64 or arm64 (D-14)")
	file := fs.String("file", "", "the build to sign")
	dir := fs.String("out", "", "output directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *key == "" || *file == "" || *dir == "" || *version == "" {
		return errors.New("--key, --version, --file and --out are required")
	}
	if *arch != "amd64" && *arch != "arm64" {
		return errors.New("--arch must be amd64 or arm64")
	}
	if _, _, err := update.ParseVersionStrict(*version); err != nil {
		return err
	}
	priv, err := readKey(*key)
	if err != nil {
		return err
	}
	sum, size, err := hashFile(*file)
	if err != nil {
		return err
	}
	m := update.Manifest{Product: *product, Channel: *channel, Version: *version,
		File: fmt.Sprintf("%s-%s-linux-%s", *product, *version, *arch), Size: size, SHA256: sum,
		Created: time.Now().UTC().Format(time.RFC3339)}
	mb, sig, err := update.Sign(m, priv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*dir, "manifest.json"), mb, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*dir, "manifest.sig"), update.SignatureText(sig), 0o644); err != nil {
		return err
	}
	if err := copyFile(*file, filepath.Join(*dir, m.File)); err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "%s %s %d %s\n", m.File, m.Version, m.Size, m.SHA256)
	return err
}

func verifyCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	product := fs.String("product", update.ProductAgent, "expected product")
	channel := fs.String("channel", update.ChannelStable, "expected channel")
	dir := fs.String("dir", "", "directory with manifest.json, manifest.sig and the build")
	trust := fs.String("trust", "", "trust this base64 public key instead of the release key (tests)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" {
		return errors.New("--dir is required")
	}
	if *trust != "" {
		pub, err := base64.StdEncoding.DecodeString(*trust)
		if err != nil || len(pub) != ed25519.PublicKeySize {
			return errors.New("invalid --trust key")
		}
		update.TrustedPublicKeys = []ed25519.PublicKey{pub}
	}
	m, err := verifyDir(*product, *channel, *dir)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "product: %s\nchannel: %s\nversion: %s\nfile: %s\nsize: %d\nsha256: %s\n", m.Product, m.Channel, m.Version, m.File, m.Size, m.SHA256)
	return err
}

// verifyDir checks the signature for product and channel, then the build by
// size and SHA-256 (v2 tools/release verifyDir).
func verifyDir(product, channel, dir string) (update.Manifest, error) {
	mb, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return update.Manifest{}, err
	}
	sig, err := os.ReadFile(filepath.Join(dir, "manifest.sig"))
	if err != nil {
		return update.Manifest{}, err
	}
	m, err := update.VerifyFor(product, channel, mb, sig)
	if err != nil {
		return update.Manifest{}, err
	}
	if m.File == "manifest.json" || m.File == "manifest.sig" {
		return update.Manifest{}, fmt.Errorf("manifest names reserved file %q", m.File)
	}
	sum, size, err := hashFile(filepath.Join(dir, m.File))
	if err != nil {
		return update.Manifest{}, err
	}
	if size != m.Size {
		return update.Manifest{}, fmt.Errorf("%s has size %d, manifest says %d", m.File, size, m.Size)
	}
	if !strings.EqualFold(sum, m.SHA256) {
		return update.Manifest{}, fmt.Errorf("%s has sha256 %s, manifest says %s", m.File, sum, m.SHA256)
	}
	return m, nil
}

func hashFile(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	if !st.Mode().IsRegular() {
		return "", 0, fmt.Errorf("%s is not a regular file", path)
	}
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
