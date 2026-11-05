package update

import (
	"encoding/json"
	"errors"
	"fmt"
)

const (
	OpCheck        = "update.check"
	OpFetch        = "update.fetch"
	ProductDesktop = "aurora-desktop"
	ProductAgent   = "aurora-agent"
	ProductRelay   = "aurora-relay"
	ChannelStable  = "stable"
)

type CheckArgs struct {
	Product string `json:"product"`
	Channel string `json:"channel"`
}

type CheckResult struct {
	Manifest []byte `json:"manifest"`
	Sig      []byte `json:"sig"`
}

type FetchArgs struct {
	Product string `json:"product"`
	Channel string `json:"channel"`
	Version string `json:"version"`
	Offset  int64  `json:"offset"`
}

type FetchStart struct {
	Size   int64 `json:"size"`
	Offset int64 `json:"offset"`
}

// VerifyTrusted accepts a signature in either wire text form or raw signature
// form. A manifest that names its key is checked against that key only, so a
// build that trusts several keys can rotate them without accepting a signature
// from the wrong one.
func VerifyTrusted(manifest, sig []byte) (Manifest, error) {
	decoded, err := DecodeSignature(sig)
	if err != nil {
		decoded = sig
	}
	var head struct {
		KeyID string `json:"key_id"`
	}
	_ = json.Unmarshal(manifest, &head) // best effort: the signature still decides
	var last error = errors.New("no trusted update key")
	matched := false
	for _, key := range TrustedPublicKeys {
		if head.KeyID != "" && head.KeyID != KeyID(key) {
			continue
		}
		matched = true
		m, e := Verify(manifest, decoded, key)
		if e == nil {
			return m, nil
		}
		last = e
	}
	if head.KeyID != "" && !matched {
		return Manifest{}, fmt.Errorf("manifest is signed with release key %s, which this build does not trust", head.KeyID)
	}
	return Manifest{}, fmt.Errorf("trusted update verification: %w", last)
}

// VerifyFor is VerifyTrusted plus a check that the signed manifest is for the
// expected product and channel. Any mismatch fails closed and returns an empty
// Manifest, so a valid signature for one product cannot be served as another.
func VerifyFor(product, channel string, manifestBytes, sig []byte) (Manifest, error) {
	m, err := VerifyTrusted(manifestBytes, sig)
	if err != nil {
		return Manifest{}, err
	}
	if m.Product != product {
		return Manifest{}, fmt.Errorf("manifest product %q does not match expected product %q", m.Product, product)
	}
	if m.Channel != channel {
		return Manifest{}, fmt.Errorf("manifest channel %q does not match expected channel %q", m.Channel, channel)
	}
	return m, nil
}
