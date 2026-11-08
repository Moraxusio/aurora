package update

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
)

// Policy is shipped beside the builds, never downloaded from an untrusted
// endpoint. The exact bytes are Ed25519-signed with the release key.
type Policy struct {
	Product string   `json:"product"`
	Channel string   `json:"channel"`
	Created string   `json:"created"`
	KeyID   string   `json:"key_id"`
	Revoked []string `json:"revoked"`
	MinOK   string   `json:"min_ok,omitempty"`
}

func (p Policy) Validate() error {
	if p.Product != ProductAgent || p.Channel != ChannelStable || p.Created == "" {
		return errors.New("invalid upgrade policy")
	}
	for _, v := range append(append([]string{}, p.Revoked...), p.MinOK) {
		if v != "" {
			if _, _, err := ParseVersionStrict(v); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p Policy) CheckTarget(current, target string) error {
	if err := p.TargetRefusal(target); err != nil {
		return err
	}
	cmp, err := CompareVersionStrict(target, current)
	if err != nil {
		return err
	}
	if cmp > 0 {
		return nil
	}
	if cmp == 0 {
		return errors.New("已是此版本，无需升级")
	}
	for _, v := range p.Revoked {
		if CompareVersion(v, current) == 0 {
			return nil
		}
	}
	return errors.New("不能降级未撤回的版本")
}

func (p Policy) TargetRefusal(target string) error {
	if err := p.Validate(); err != nil {
		return err
	}
	if _, _, err := ParseVersionStrict(target); err != nil {
		return err
	}
	for _, v := range p.Revoked {
		if CompareVersion(v, target) == 0 {
			return fmt.Errorf("版本 %s 已撤回，拒绝安装", target)
		}
	}
	if p.MinOK != "" && CompareVersion(target, p.MinOK) < 0 {
		return fmt.Errorf("版本低于最低安全版本 %s", p.MinOK)
	}
	return nil
}

func SignPolicy(p Policy, key ed25519.PrivateKey) ([]byte, []byte, error) {
	if len(key) != ed25519.PrivateKeySize {
		return nil, nil, errors.New("invalid key")
	}
	p.KeyID = KeyID(key.Public().(ed25519.PublicKey))
	if p.Revoked == nil {
		p.Revoked = []string{}
	}
	if err := p.Validate(); err != nil {
		return nil, nil, err
	}
	b, err := json.Marshal(p)
	if err != nil {
		return nil, nil, err
	}
	return b, ed25519.Sign(key, b), nil
}

func VerifyPolicy(b, sig []byte) (Policy, error) {
	var p Policy
	if err := json.Unmarshal(b, &p); err != nil {
		return p, err
	}
	s, err := DecodeSignature(sig)
	if err != nil {
		s = sig
	}
	for _, k := range TrustedPublicKeys {
		if p.KeyID == KeyID(k) && ed25519.Verify(k, b, s) {
			return p, p.Validate()
		}
	}
	return Policy{}, errors.New("升级撤回清单的签名无效")
}
