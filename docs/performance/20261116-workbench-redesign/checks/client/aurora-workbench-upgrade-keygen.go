package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
)

func main() {
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil { panic(err) }
	for name, data := range map[string][]byte{"fixture.key": key, "trust.pub": pub} {
		if err := os.WriteFile(filepath.Join(os.Args[1], name), []byte(base64.StdEncoding.EncodeToString(data)), 0600); err != nil { panic(err) }
	}
}
