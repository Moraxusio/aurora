package wire

import (
	"strconv"
	"strings"
)

// VersionStamp returns the build stamp of a release version such as
// "2.0.0+20261026195600", which orders builds; development builds have none (0).
func VersionStamp(v string) int64 {
	_, stamp, ok := strings.Cut(v, "+")
	if !ok {
		return 0
	}
	n, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}
