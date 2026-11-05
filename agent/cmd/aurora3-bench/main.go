// aurora3-bench is the Go reference for the Dart client benchmark
// (app/packages/aurora_wire/bin/bench.dart): the same items over the same
// path (pinned TLS, Hello, hashicorp/yamux), measured with v2's client stack.
//
//	aurora3-bench -addr host:port -pin HEX -token HEX
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hashicorp/yamux"

	"aurora3/internal/wire"
)

func main() {
	addr := flag.String("addr", "", "agent address")
	pin := flag.String("pin", "", "certificate pin")
	token := flag.String("token", "", "token")
	flag.Parse()
	if err := run(*addr, *pin, *token); err != nil {
		fmt.Fprintln(os.Stderr, "bench:", err)
		os.Exit(1)
	}
}

func pct(us []time.Duration, q float64) string {
	s := append([]time.Duration(nil), us...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return fmt.Sprintf("%.2f", float64(s[int(float64(len(s)-1)*q+0.5)].Microseconds())/1000)
}

func mbps(n int64, d time.Duration) string { return fmt.Sprintf("%.1f", float64(n)/float64(d.Microseconds())) }

func run(addr, pin, token string) error {
	start := time.Now()
	raw, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return err
	}
	raw.(*net.TCPConn).SetNoDelay(true)
	c := tls.Client(raw, wire.PinnedTLS(pin))
	if err := wire.WriteJSON(c, wire.Hello{Role: wire.RoleClient, Token: token, Version: wire.Version, Client: "bench-go"}); err != nil {
		return err
	}
	var reply wire.HelloReply
	if err := wire.ReadJSON(c, &reply); err != nil {
		return err
	}
	if !reply.OK {
		return errors.New(reply.Error)
	}
	ys, err := yamux.Client(c, wire.MuxConfig())
	if err != nil {
		return err
	}
	s := wire.NewMux(ys, nil)
	defer s.Close()
	fmt.Printf("dial (tcp+tls+hello)      %.1f ms\n", float64(time.Since(start).Microseconds())/1000)
	ctx := context.Background()
	call := func() error { return wire.Call(ctx, s, "test.echo", map[string]string{"text": "x"}, nil) }
	for i := 0; i < 50; i++ {
		_ = call()
	}
	var rtt []time.Duration
	for i := 0; i < 500; i++ {
		t := time.Now()
		if err := call(); err != nil {
			return err
		}
		rtt = append(rtt, time.Since(t))
	}
	fmt.Printf("unary call, idle          p50 %s ms  p99 %s ms\n", pct(rtt, .5), pct(rtt, .99))
	var pings []time.Duration
	for i := 0; i < 200; i++ {
		d, err := ys.Ping()
		if err != nil {
			return err
		}
		pings = append(pings, d)
	}
	fmt.Printf("yamux ping, idle          p50 %s ms  p99 %s ms\n", pct(pings, .5), pct(pings, .99))

	var n atomic.Int64
	until := time.Now().Add(2 * time.Second)
	t0 := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < 64; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(until) {
				if call() == nil {
					n.Add(1)
				}
			}
		}()
	}
	wg.Wait()
	fmt.Printf("unary calls, 64 parallel  %.0f /s\n", float64(n.Load())/time.Since(t0).Seconds())

	const size = 512 << 20
	t0 = time.Now()
	if err := download(s, size); err != nil {
		return err
	}
	fmt.Printf("download, 1 stream        %s MB/s\n", mbps(size, time.Since(t0)))
	t0 = time.Now()
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() { errs <- download(s, size/4) }()
	}
	for i := 0; i < 4; i++ {
		if err := <-errs; err != nil {
			return err
		}
	}
	fmt.Printf("download, 4 streams       %s MB/s (total)\n", mbps(size, time.Since(t0)))
	t0 = time.Now()
	if err := upload(s, size); err != nil {
		return err
	}
	fmt.Printf("upload, 1 stream          %s MB/s\n", mbps(size, time.Since(t0)))

	dl, err := s.OpenStream()
	if err != nil {
		return err
	}
	_ = wire.WriteRequest(dl, "test.source", map[string]int64{"bytes": 4 << 30})
	var r wire.Response
	if err := wire.ReadJSON(dl, &r); err != nil {
		return err
	}
	var bulk atomic.Int64
	go func() {
		for {
			typ, p, err := wire.ReadFrame(dl)
			if err != nil || typ == wire.TypeEnd {
				return
			}
			bulk.Add(int64(len(p)))
		}
	}()
	time.Sleep(500 * time.Millisecond)
	pipe, err := s.OpenStream()
	if err != nil {
		return err
	}
	_ = wire.WriteRequest(pipe, "test.pipe", nil)
	if err := wire.ReadJSON(pipe, &r); err != nil {
		return err
	}
	var keys []time.Duration
	b0, busy := bulk.Load(), time.Now()
	for i := 0; i < 200; i++ {
		t := time.Now()
		_ = wire.WriteFrame(pipe, wire.TypeData, []byte{'a'})
		if _, _, err := wire.ReadFrame(pipe); err != nil {
			return err
		}
		keys = append(keys, time.Since(t))
	}
	during := mbps(bulk.Load()-b0, time.Since(busy))
	dl.Close()
	fmt.Printf("key echo during download  p50 %s ms  p99 %s ms  (download ran at %s MB/s)\n", pct(keys, .5), pct(keys, .99), during)
	return nil
}

func download(s *wire.Mux, size int64) error {
	st, err := s.OpenStream()
	if err != nil {
		return err
	}
	defer st.Close()
	_ = wire.WriteRequest(st, "test.source", map[string]int64{"bytes": size})
	var r wire.Response
	if err := wire.ReadJSON(st, &r); err != nil {
		return err
	}
	var got int64
	for {
		typ, p, err := wire.ReadFrame(st)
		if err != nil {
			return err
		}
		if typ == wire.TypeEnd {
			break
		}
		got += int64(len(p))
	}
	if got != size {
		return fmt.Errorf("download %d of %d", got, size)
	}
	return nil
}

func upload(s *wire.Mux, size int64) error {
	st, err := s.OpenStream()
	if err != nil {
		return err
	}
	defer st.Close()
	_ = wire.WriteRequest(st, "test.sink", nil)
	buf := make([]byte, wire.DataChunk)
	for off := int64(0); off < size; off += int64(len(buf)) {
		if err := wire.WriteFrame(st, wire.TypeData, buf); err != nil {
			return err
		}
	}
	_ = wire.WriteFrame(st, wire.TypeEnd, nil)
	var r wire.Response
	if err := wire.ReadJSON(st, &r); err != nil {
		return err
	}
	if !r.OK {
		return errors.New(r.Error)
	}
	return nil
}
