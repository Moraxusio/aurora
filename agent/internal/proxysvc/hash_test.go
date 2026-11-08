package proxysvc

import (
	"crypto/sha256"
	"encoding/hex"
)

// trojanHash is hex(SHA-224(secret)), what the node expects first.
func trojanHash(secret string) string {
	s := sha256.Sum224([]byte(secret))
	return hex.EncodeToString(s[:])
}
