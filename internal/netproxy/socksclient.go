package netproxy

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"time"
)

// DialSocks5 connects to target through a SOCKS5 proxy that requires a
// username and password. It exists so the CLI can prove the whole path works
// without wiring a real program into it.
func DialSocks5(ctx context.Context, proxyAddr, user, pass, target string) (net.Conn, error) {
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	port, ok := atoiPort(portStr)
	if !ok {
		return nil, errors.New("目标端口无效")
	}
	if len(host) > 255 {
		return nil, errors.New("目标域名过长")
	}
	var d net.Dialer
	c, err := d.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(8 * time.Second)
	if dl, ok := ctx.Deadline(); ok && dl.Before(deadline) {
		deadline = dl
	}
	_ = c.SetDeadline(deadline)

	if _, err := c.Write([]byte{0x05, 0x01, 0x02}); err != nil {
		c.Close()
		return nil, err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(c, reply); err != nil {
		c.Close()
		return nil, err
	}
	if reply[0] != 0x05 || reply[1] != 0x02 {
		c.Close()
		return nil, errors.New("代理不接受用户名密码认证")
	}
	req := []byte{0x01, byte(len(user))}
	req = append(req, user...)
	req = append(req, byte(len(pass)))
	req = append(req, pass...)
	if _, err := c.Write(req); err != nil {
		c.Close()
		return nil, err
	}
	if _, err := io.ReadFull(c, reply); err != nil {
		c.Close()
		return nil, err
	}
	if reply[1] != 0x00 {
		c.Close()
		return nil, errors.New("代理认证失败")
	}
	conn := []byte{0x05, 0x01, 0x00}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			conn = append(conn, 0x01)
			conn = append(conn, v4...)
		} else {
			conn = append(conn, 0x04)
			conn = append(conn, ip.To16()...)
		}
	} else {
		conn = append(conn, 0x03, byte(len(host)))
		conn = append(conn, host...)
	}
	conn = append(conn, byte(port>>8), byte(port))
	if _, err := c.Write(conn); err != nil {
		c.Close()
		return nil, err
	}
	head := make([]byte, 4)
	if _, err := io.ReadFull(c, head); err != nil {
		c.Close()
		return nil, err
	}
	if head[1] != 0x00 {
		c.Close()
		return nil, errors.New("代理拒绝连接目标：代码 " + strconv.Itoa(int(head[1])))
	}
	switch head[3] {
	case 0x01:
		_, err = io.ReadFull(c, make([]byte, 4+2))
	case 0x04:
		_, err = io.ReadFull(c, make([]byte, 16+2))
	case 0x03:
		var l [1]byte
		if _, err = io.ReadFull(c, l[:]); err == nil {
			_, err = io.ReadFull(c, make([]byte, int(l[0])+2))
		}
	}
	if err != nil {
		c.Close()
		return nil, err
	}
	_ = c.SetDeadline(time.Time{})
	return c, nil
}
