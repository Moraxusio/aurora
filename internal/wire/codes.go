package wire

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
)

// JoinCode lets a new agent register with a relay ("AJ1-..."). ClientCode
// lets a client reach the relay ("AC1-..."). Both are base64url JSON.
type JoinCode struct {
	Addr  string `json:"a"`
	Pin   string `json:"p"`
	Token string `json:"t"`
}

const (
	joinPrefix   = "AJ1-"
	clientPrefix = "AC1-"
)

func encodeCode(prefix string, c JoinCode) string {
	b, _ := json.Marshal(c)
	return prefix + base64.RawURLEncoding.EncodeToString(b)
}

func decodeCode(prefix, s string) (JoinCode, error) {
	var c JoinCode
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, prefix) {
		return c, errors.New("代码格式不正确")
	}
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(s, prefix))
	if err != nil || json.Unmarshal(b, &c) != nil || c.Addr == "" || len(c.Pin) != 64 || len(c.Token) < 32 {
		return JoinCode{}, errors.New("代码内容无效")
	}
	return c, nil
}

func (c JoinCode) Agent() string  { return encodeCode(joinPrefix, c) }
func (c JoinCode) Client() string { return encodeCode(clientPrefix, c) }

func ParseJoinCode(s string) (JoinCode, error)   { return decodeCode(joinPrefix, s) }
func ParseClientCode(s string) (JoinCode, error) { return decodeCode(clientPrefix, s) }
