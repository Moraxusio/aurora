package statecrypt

import (
	"bytes"
	"testing"
)

func TestEncryptedStateRejectsPlaintextWrongContextAndCorruption(t *testing.T) {
	codec, err := New(bytes.Repeat([]byte{7}, KeyBytes))
	if err != nil {
		t.Fatal(err)
	}
	plain := []byte("private source and test token")
	cipher, err := codec.Seal("session:one", plain)
	if err != nil || bytes.Contains(cipher, plain) || len(cipher)-len(plain) != Overhead {
		t.Fatalf("envelope: %v", err)
	}
	other, err := codec.Seal("session:one", plain)
	if err != nil || bytes.Equal(other, cipher) {
		t.Fatal("reused ciphertext for same record")
	}
	value, err := codec.Open("session:one", cipher)
	if err != nil || !bytes.Equal(value, plain) {
		t.Fatalf("round-trip: %v", err)
	}
	if _, err := codec.Open("session:two", cipher); err == nil {
		t.Fatal("accepted a swapped record")
	}
	if _, err := codec.Open("session:one", plain); err == nil {
		t.Fatal("accepted plaintext")
	}
	cipher[len(cipher)-1] ^= 1
	if _, err := codec.Open("session:one", cipher); err == nil {
		t.Fatal("accepted unauthenticated data")
	}
}
