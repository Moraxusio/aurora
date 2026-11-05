package wire

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/hashicorp/yamux"
)

func TestFrameRoundTripAndLimits(t *testing.T) {
	var b bytes.Buffer
	if err := WriteFrame(&b, TypeData, []byte("abc")); err != nil {
		t.Fatal(err)
	}
	typ, p, err := ReadFrame(&b)
	if err != nil || typ != TypeData || string(p) != "abc" {
		t.Fatalf("%q %q %v", typ, p, err)
	}
	if err := WriteFrame(&b, TypeData, make([]byte, MaxFrame)); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatal("oversize frame accepted")
	}
	b.Reset()
	b.Write([]byte{0xff, 0xff, 0xff, 0xff})
	if _, _, err := ReadFrame(&b); err == nil {
		t.Fatal("oversize header accepted")
	}
}

func TestPinnedTLS(t *testing.T) {
	dir := t.TempDir()
	cert, pin, err := LoadOrCreateCert(dir, "test")
	if err != nil {
		t.Fatal(err)
	}
	if _, pin2, _ := LoadOrCreateCert(dir, "test"); pin2 != pin {
		t.Fatal("certificate not reused")
	}
	ln, _ := tls.Listen("tcp", "127.0.0.1:0", ServerTLS(cert))
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { _ = c.(*tls.Conn).Handshake(); c.Close() }()
		}
	}()
	c, err := tls.Dial("tcp", ln.Addr().String(), PinnedTLS(pin))
	if err != nil {
		t.Fatalf("right pin rejected: %v", err)
	}
	c.Close()
	if _, err := tls.Dial("tcp", ln.Addr().String(), PinnedTLS(NewToken())); err == nil {
		t.Fatal("wrong pin accepted")
	}
}

func TestCallOverMux(t *testing.T) {
	a, b := net.Pipe()
	srv, _ := yamux.Server(a, MuxConfig())
	ycli, _ := yamux.Client(b, MuxConfig())
	cli := NewMux(ycli, nil)
	defer srv.Close()
	defer cli.Close()
	go func() {
		for {
			st, err := srv.AcceptStream()
			if err != nil {
				return
			}
			go func() {
				defer st.Close()
				var req Request
				_ = ReadJSON(st, &req)
				switch req.Op {
				case "echo":
					_ = WriteJSON(st, OKResponse(map[string]any{"args": req.Args}))
				case "slow":
					time.Sleep(time.Second)
				default:
					_ = WriteJSON(st, ErrResponse(Errf(CodeNotFound, "未知操作 %s", req.Op)))
				}
			}()
		}
	}()
	var out struct{ Args map[string]int }
	if err := Call(context.Background(), cli, "echo", map[string]int{"x": 1}, &out); err != nil || out.Args["x"] != 1 {
		t.Fatalf("%v %v", out, err)
	}
	err := Call(context.Background(), cli, "nope", nil, nil)
	if CodeOf(err) != CodeNotFound {
		t.Fatalf("code %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := Call(ctx, cli, "slow", nil, nil); CodeOf(err) != CodeUnavailable {
		t.Fatalf("timeout not reported: %v", err)
	}
}

func TestVersionAndTokens(t *testing.T) {
	if !MajorCompatible("2.0", "2.7") || MajorCompatible("2.0", "3.0") || MajorCompatible("", "") {
		t.Fatal("version compatibility")
	}
	if TokenEqual("", "") || !TokenEqual("ab", "ab") || TokenEqual("ab", "ac") {
		t.Fatal("token compare")
	}
	if len(NewToken()) != 64 {
		t.Fatal("token length")
	}
}
