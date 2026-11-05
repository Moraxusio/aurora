//go:build linux

package files

import (
	"os/user"
	"strconv"
	"sync"
)

// idCache maps uid/gid to names (pure Go: reads /etc/passwd and /etc/group).
type idCache struct {
	mu     sync.Mutex
	users  map[uint32]string
	groups map[uint32]string
}

var idNames = &idCache{users: map[uint32]string{}, groups: map[uint32]string{}}

func (c *idCache) user(id uint32) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if n, ok := c.users[id]; ok {
		return n
	}
	n := strconv.FormatUint(uint64(id), 10)
	if u, err := user.LookupId(n); err == nil {
		n = u.Username
	}
	c.users[id] = n
	return n
}

func (c *idCache) group(id uint32) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if n, ok := c.groups[id]; ok {
		return n
	}
	n := strconv.FormatUint(uint64(id), 10)
	if g, err := user.LookupGroupId(n); err == nil {
		n = g.Name
	}
	c.groups[id] = n
	return n
}
