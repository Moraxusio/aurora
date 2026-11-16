package devprocess

import (
	"errors"
	"sync"
)

var processSlots = make(chan struct{}, 8)

// Reserve is shared by LSP, DAP, tasks and MCP so extensions cannot bypass the
// host's process budget. The lease is released only after process-tree cleanup.
func Reserve() (func(), error) {
	select {
	case processSlots <- struct{}{}:
		var once sync.Once
		return func() { once.Do(func() { <-processSlots }) }, nil
	default:
		return nil, errors.New("开发进程已达到 8 个并发上限")
	}
}
