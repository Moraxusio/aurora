//go:build ignore

// Creates throwaway local-agent test keys, never production credentials.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
)

func main() {
	if len(os.Args) != 2 {
		panic("fixture directory required")
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	for name, b := range map[string][]byte{"fixture.key": priv, "fixture.pub": pub} {
		if err = os.WriteFile(filepath.Join(os.Args[1], name), []byte(base64.StdEncoding.EncodeToString(b)), 0600); err != nil {
			panic(err)
		}
	}
}
