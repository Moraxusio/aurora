package update

import (
	"fmt"
	"regexp"
	"strconv"
)

// strictVersionRE accepts MAJOR.MINOR.PATCH with an optional +STAMP build stamp
// of at most 18 decimal digits. Prerelease suffixes such as "-dev" are rejected.
var strictVersionRE = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\+([0-9]{1,18}))?$`)

// ParseVersionStrict returns the semver core and the build stamp of v. A missing
// stamp counts as 0. Malformed input is an error; unlike CompareVersion, it is
// never read as zero.
func ParseVersionStrict(v string) ([3]int64, int64, error) {
	m := strictVersionRE.FindStringSubmatch(v)
	if m == nil {
		return [3]int64{}, 0, fmt.Errorf("malformed version %q", v)
	}
	var core [3]int64
	for i := range core {
		n, err := strconv.ParseInt(m[i+1], 10, 64)
		if err != nil {
			return [3]int64{}, 0, fmt.Errorf("malformed version %q: %w", v, err)
		}
		core[i] = n
	}
	var stamp int64
	if m[4] != "" {
		stamp, _ = strconv.ParseInt(m[4], 10, 64) // at most 18 digits, always fits int64
	}
	return core, stamp, nil
}

// CompareVersionStrict compares two versions like CompareVersion, but returns an
// error if either one is malformed.
func CompareVersionStrict(a, b string) (int, error) {
	ac, as, err := ParseVersionStrict(a)
	if err != nil {
		return 0, err
	}
	bc, bs, err := ParseVersionStrict(b)
	if err != nil {
		return 0, err
	}
	for i := range ac {
		if ac[i] != bc[i] {
			if ac[i] < bc[i] {
				return -1, nil
			}
			return 1, nil
		}
	}
	switch {
	case as < bs:
		return -1, nil
	case as > bs:
		return 1, nil
	}
	return 0, nil
}
