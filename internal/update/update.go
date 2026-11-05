// Package update defines signed release manifests and version comparison.
package update

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const MaxFileSize int64 = 2 << 30

type Manifest struct {
	Product string `json:"product"`
	Channel string `json:"channel"`
	Version string `json:"version"`
	File    string `json:"file"`
	Size    int64  `json:"size"`
	SHA256  string `json:"sha256"`
	Created string `json:"created"`
	MinFrom string `json:"min_from,omitempty"`
	// KeyID names the release key that signed this manifest: the first 16 hex
	// digits of the SHA-256 of its public key. It lets a build carry several
	// trusted keys across a rotation, and it makes a manifest signed by an
	// unknown key fail with that reason instead of a generic "bad signature".
	// Old manifests have none and are still accepted.
	KeyID string `json:"key_id,omitempty"`
}

var keyIDRE = regexp.MustCompile(`^[0-9a-f]{16}$`)

// KeyID is the short, stable id of a release key.
func KeyID(pub ed25519.PublicKey) string {
	h := sha256.Sum256(pub)
	return hex.EncodeToString(h[:])[:16]
}

var nameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
var hexRE = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

func validate(m Manifest) error {
	if !nameRE.MatchString(m.Product) || !nameRE.MatchString(m.Channel) {
		return errors.New("invalid product or channel")
	}
	if m.Version == "" || strings.ContainsAny(m.Version, " \t\r\n") {
		return errors.New("invalid version")
	}
	if m.File == "" || strings.ContainsAny(m.File, `/\\:`) || m.File == "." || m.File == ".." {
		return errors.New("invalid file")
	}
	if m.Size < 0 || m.Size > MaxFileSize {
		return errors.New("invalid size")
	}
	if !hexRE.MatchString(m.SHA256) {
		return errors.New("invalid sha256")
	}
	if m.Created == "" {
		return errors.New("missing created")
	}
	if m.KeyID != "" && !keyIDRE.MatchString(m.KeyID) {
		return errors.New("invalid key id")
	}
	return nil
}

func Verify(manifestBytes, sig []byte, pub ed25519.PublicKey) (Manifest, error) {
	var m Manifest
	if len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, manifestBytes, sig) {
		return m, errors.New("invalid manifest signature")
	}
	if err := json.Unmarshal(manifestBytes, &m); err != nil {
		return m, fmt.Errorf("manifest json: %w", err)
	}
	if err := validate(m); err != nil {
		return m, err
	}
	if m.KeyID != "" && m.KeyID != KeyID(pub) {
		return m, errors.New("manifest key id does not match the signing key")
	}
	return m, nil
}

func Sign(m Manifest, private ed25519.PrivateKey) ([]byte, []byte, error) {
	if len(private) != ed25519.PrivateKeySize {
		return nil, nil, errors.New("invalid private key")
	}
	if m.KeyID == "" {
		m.KeyID = KeyID(private.Public().(ed25519.PublicKey))
	}
	if err := validate(m); err != nil {
		return nil, nil, err
	}
	b, err := json.Marshal(m)
	if err != nil {
		return nil, nil, err
	}
	return b, ed25519.Sign(private, b), nil
}

func SignatureText(sig []byte) []byte { return []byte(base64.StdEncoding.EncodeToString(sig) + "\n") }
func DecodeSignature(s []byte) ([]byte, error) {
	return base64.StdEncoding.DecodeString(strings.TrimSpace(string(s)))
}
func HashBytes(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// CompareVersion compares semver core, then the numeric build stamp after '+'.
func CompareVersion(a, b string) int {
	ac, as := splitVersion(a)
	bc, bs := splitVersion(b)
	for i := 0; i < 3; i++ {
		if ac[i] != bc[i] {
			if ac[i] < bc[i] {
				return -1
			}
			return 1
		}
	}
	if as < bs {
		return -1
	}
	if as > bs {
		return 1
	}
	return 0
}
func splitVersion(v string) ([3]int64, int64) {
	var core [3]int64
	p := strings.SplitN(v, "+", 2)
	nums := strings.SplitN(strings.TrimPrefix(p[0], "v"), ".", 3)
	for i := range nums {
		if i == 3 {
			break
		}
		n, _ := strconv.ParseInt(nums[i], 10, 64)
		core[i] = n
	}
	var stamp int64
	if len(p) == 2 {
		stamp, _ = strconv.ParseInt(p[1], 10, 64)
	}
	return core, stamp
}

func Validate(m Manifest) error { return validate(m) }
