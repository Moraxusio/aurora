package netfwd

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	"aurora3/internal/wire"
)

func TestCheckDial(t *testing.T) {
	for _, bad := range []dialArgs{{Port: 0}, {Port: 70000}, {Host: "a b", Port: 80}, {Host: "a/b", Port: 80}, {Host: "a\x00", Port: 80}} {
		a := bad
		if err := checkDial(&a); wire.CodeOf(err) != wire.CodeBadRequest {
			t.Errorf("%+v: want bad_request, got %v", bad, err)
		}
	}
	a := dialArgs{Port: 22}
	if err := checkDial(&a); err != nil || a.Host != "127.0.0.1" {
		t.Fatalf("default host: %+v %v", a, err)
	}
}

// net.dial: the Response, then bytes both ways; the server's close after
// its answer ends the stream.
func TestNetDialCarriesBytes(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		b, _ := io.ReadAll(c) // until the client half-closes
		_, _ = c.Write(append([]byte("echo:"), b...))
	}()
	client, server := net.Pipe()
	defer client.Close()
	args, _ := json.Marshal(map[string]any{"port": ln.Addr().(*net.TCPAddr).Port})
	done := make(chan error, 1)
	go func() {
		err := (&Env{}).netDial(context.Background(), &halfPipe{Conn: server}, args)
		server.Close() // as serveStream does when the handler returns
		done <- err
	}()
	var resp wire.Response
	if err := wire.ReadJSON(client, &resp); err != nil || !resp.OK {
		t.Fatalf("response %+v %v", resp, err)
	}
	if _, err := client.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	// net.Pipe has no half-close: an expired read deadline on the agent's
	// side stands in for it (halfPipe turns it into EOF).
	_ = server.SetReadDeadline(time.Now())
	_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, _ := io.ReadAll(client)
	if !bytes.Equal(got, []byte("echo:hello")) {
		t.Fatalf("got %q", got)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestNetDialRefused(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	args := []byte(`{"port":` + strconv.Itoa(port) + `}`)
	client, server := net.Pipe()
	defer client.Close()
	err := (&Env{}).netDial(context.Background(), server, args)
	if wire.CodeOf(err) != wire.CodeUnavailable {
		t.Fatalf("closed port: %v", err)
	}
}

// halfPipe turns a read deadline into EOF, standing in for the client's
// half-close on a yamux stream.
type halfPipe struct{ net.Conn }

func (h *halfPipe) Read(p []byte) (int, error) {
	n, err := h.Conn.Read(p)
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return n, io.EOF
	}
	return n, err
}
