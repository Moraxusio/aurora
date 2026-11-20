package statecrypt

import (
	"bytes"
	"testing"
)

func TestDPAPIStateKeyRoundTrip(t *testing.T) {
	key := bytes.Repeat([]byte{19}, KeyBytes)
	expected, err := New(key)
	if err != nil {
		t.Fatal(err)
	}
	record, err := WrapKey(key)
	if err != nil || bytes.Contains(record, key) {
		t.Fatalf("could not wrap key: %v", err)
	}
	loaded, err := UnwrapKey(record)
	if err != nil || loaded.ObjectID("fixture", nil) != expected.ObjectID("fixture", nil) {
		t.Fatalf("unwrapped key differs: %v", err)
	}
	if _, err := UnwrapKey(key); err == nil {
		t.Fatal("accepted a plaintext key")
	}
	if _, err := UnwrapKey(record[:len(record)-10]); err == nil {
		t.Fatal("accepted a truncated DPAPI record")
	}
	if _, err := UserDPAPI(record[len(windowsKeyHeader):], []byte("wrong component"), false); err == nil {
		t.Fatal("accepted a DPAPI record from a different domain")
	}
	bound, err := WrapKeyFor(key, "synthetic-agent-one")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := UnwrapKeyFor(bound, "synthetic-agent-two"); err == nil {
		t.Fatal("accepted a DPAPI key copied from a different agent")
	}
}
