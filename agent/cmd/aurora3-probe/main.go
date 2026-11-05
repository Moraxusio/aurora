// aurora3-probe is a test tool: it dials an agent the way the client does
// (pinned TLS, Hello, yamux) and runs one operation. It prints the result as
// JSON. Used to check a running agent and as the Go side of client
// benchmarks.
//
//	aurora3-probe -addr host:port -pin HEX -token HEX [-op agent.info] [-args JSON]
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/hashicorp/yamux"

	"aurora3/internal/wire"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:17710", "agent address")
	pin := flag.String("pin", "", "certificate pin (hex SHA-256)")
	token := flag.String("token", "", "direct token")
	op := flag.String("op", "agent.info", "operation")
	args := flag.String("args", "", "operation arguments (JSON)")
	flag.Parse()
	sess, reply, err := dial(*addr, *pin, *token)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dial:", err)
		os.Exit(1)
	}
	defer sess.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var raw json.RawMessage
	if *args != "" {
		raw = json.RawMessage(*args)
	}
	var out json.RawMessage
	if err := wire.Call(ctx, wire.NewMux(sess, nil), *op, raw, &out); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v (%s)\n", *op, err, wire.CodeOf(err))
		os.Exit(1)
	}
	b, _ := json.Marshal(map[string]any{"server": reply.Server.Name, "version": reply.Server.Version, "result": out})
	fmt.Println(string(b))
}

func dial(addr, pin, token string) (*yamux.Session, wire.HelloReply, error) {
	raw, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return nil, wire.HelloReply{}, err
	}
	if tc, ok := raw.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	c := tls.Client(raw, wire.PinnedTLS(pin))
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	if err := wire.WriteJSON(c, wire.Hello{Role: wire.RoleClient, Token: token, Version: wire.Version, Client: "aurora3-probe"}); err != nil {
		c.Close()
		return nil, wire.HelloReply{}, err
	}
	var reply wire.HelloReply
	if err := wire.ReadJSON(c, &reply); err != nil {
		c.Close()
		return nil, reply, err
	}
	if !reply.OK {
		c.Close()
		return nil, reply, errors.New(reply.Error)
	}
	_ = c.SetDeadline(time.Time{})
	s, err := yamux.Client(c, wire.MuxConfig())
	return s, reply, err
}
