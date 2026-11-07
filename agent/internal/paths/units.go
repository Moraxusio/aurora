// Unit names and the actions a service_actions allowlist may name (D-28). No build
// tag: the entry validates agent.actions with these too, and it builds on every
// platform.

package paths

import (
	"regexp"
	"sort"
	"strings"

	"aurora3/internal/wire"
)

// UnitName is the syntax of a systemd unit name the agent accepts (v2 monitor.go).
var UnitName = regexp.MustCompile(`^[A-Za-z0-9@_.:-]{1,128}$`)

// CheckUnit refuses a unit name that is malformed or looks like a flag.
func CheckUnit(name string) error {
	if !UnitName.MatchString(name) || strings.HasPrefix(name, "-") {
		return wire.Errf(wire.CodeBadRequest, "服务名无效")
	}
	return nil
}

// ServiceActions are the actions a service_actions allowlist may name (D-28).
var ServiceActions = []string{"restart", "start", "stop"}

// CheckActions validates one allowlist entry: a valid unit name and only the
// known actions. It returns the actions sorted, without repeats. Shared by
// the entry (agent.actions) and the systemd service (D-40).
func CheckActions(name string, actions []string) ([]string, error) {
	if err := CheckUnit(name); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []string{}
	for _, a := range actions {
		known := false
		for _, x := range ServiceActions {
			known = known || x == a
		}
		if !known {
			return nil, wire.Errf(wire.CodeBadRequest, "服务操作无效：%s", a)
		}
		if !seen[a] {
			seen[a] = true
			out = append(out, a)
		}
	}
	sort.Strings(out)
	return out, nil
}
