package entry

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
)

// Instances (D-101). One server can run several agents side by side, one per
// client, so that clients cannot affect each other: each instance has its own
// binary, systemd unit, config (token, roots, proxy), state (certificate,
// agent id, audit log, tmux), port, tmux socket and tmux units. The default
// instance (the empty name) keeps v3's original names, so an agent installed
// before instances existed is the default instance and nothing moves.
//
// Everything of a named instance sits in a sibling of the default paths
// (/etc/aurora3.d/NAME, /var/lib/aurora3.d/NAME), never inside them, so
// removing or purging the default instance cannot touch another one.

const (
	// InstancesConfigDir and InstancesStateDir hold one directory per named instance.
	InstancesConfigDir = "/etc/aurora3.d"
	InstancesStateDir  = "/var/lib/aurora3.d"
	// FirstInstancePort and LastInstancePort bound the port search of a named
	// instance (the default instance has 17710).
	FirstInstancePort = 17711
	LastInstancePort  = 17799
)

// A name is short, lower case and has no hyphen, so no unit or glob of one
// instance can match another's: "aurora3-ab-tmux-*" cannot match
// "aurora3-a-tmux-*", and none of them match the default "aurora3-tmux-*".
var instanceName = regexp.MustCompile(`^[a-z][a-z0-9]{0,15}$`)

// Words that would collide with a fixed part of a default name.
var reservedInstance = map[string]bool{"tmux": true, "upgrade": true, "agent": true, "default": true, "install": true}

// ValidInstance reports whether name can name an instance. The empty name is
// the default instance and is valid.
func ValidInstance(name string) error {
	if name == "" {
		return nil
	}
	if !instanceName.MatchString(name) {
		return fmt.Errorf("实例名 %q 无效：只能是 1 到 16 位小写字母和数字，且以字母开头", name)
	}
	if reservedInstance[name] {
		return fmt.Errorf("实例名 %q 是保留字", name)
	}
	return nil
}

// Layout is every name and path of one instance on the server.
type Layout struct {
	Instance    string // "" for the default instance
	Bin         string
	UnitName    string
	UnitPath    string
	ConfigDir   string
	ConfigPath  string
	StateDir    string
	Socket      string // tmux -L socket
	TmuxPrefix  string // transient tmux units are TmuxPrefix + <ms>
	TmuxPattern string // systemctl pattern of those units
	UpgradeUnit string // prefix of the transient upgrade unit
}

// LayoutFor returns the layout of an instance.
func LayoutFor(instance string) (Layout, error) {
	if err := ValidInstance(instance); err != nil {
		return Layout{}, err
	}
	if instance == "" {
		return Layout{
			Bin:         "/usr/local/bin/aurora3-agent",
			UnitName:    "aurora3-agent.service",
			UnitPath:    "/etc/systemd/system/aurora3-agent.service",
			ConfigDir:   "/etc/aurora3",
			ConfigPath:  DefaultConfigPath,
			StateDir:    DefaultStateDir,
			Socket:      "aurora3",
			TmuxPrefix:  "aurora3-tmux-",
			TmuxPattern: "aurora3-tmux-*",
			UpgradeUnit: "aurora3-upgrade-",
		}, nil
	}
	unit := "aurora3-agent-" + instance + ".service"
	cfgDir := InstancesConfigDir + "/" + instance
	return Layout{
		Instance:    instance,
		Bin:         "/usr/local/bin/aurora3-agent-" + instance,
		UnitName:    unit,
		UnitPath:    "/etc/systemd/system/" + unit,
		ConfigDir:   cfgDir,
		ConfigPath:  cfgDir + "/agent.json",
		StateDir:    InstancesStateDir + "/" + instance,
		Socket:      "aurora3-" + instance,
		TmuxPrefix:  "aurora3-" + instance + "-tmux-",
		TmuxPattern: "aurora3-" + instance + "-tmux-*",
		UpgradeUnit: "aurora3-" + instance + "-upgrade-",
	}, nil
}

// ListenPort is the port of a listen address, 0 when there is none.
func ListenPort(listen string) int {
	_, p, err := net.SplitHostPort(listen)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(p)
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

// ConfiguredPorts lists the ports the instances on this machine (default and
// named) are configured for, read from their config files under root (a test
// prefix; "/" on a server). The files are read leniently: an instance whose
// config does not validate still holds its port.
func ConfiguredPorts(root string) []int {
	files := []string{filepath.Join(root, DefaultConfigPath)}
	more, _ := filepath.Glob(filepath.Join(root, InstancesConfigDir, "*", "agent.json"))
	var out []int
	for _, f := range append(files, more...) {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var c struct {
			Listen string `json:"listen"`
		}
		if json.Unmarshal(b, &c) != nil {
			continue
		}
		if p := ListenPort(c.Listen); p > 0 {
			out = append(out, p)
		}
	}
	return out
}

// ListInstances returns the names of the named instances that have a config
// under root, sorted. The default instance is not in the list.
func ListInstances(root string) []string {
	m, _ := filepath.Glob(filepath.Join(root, InstancesConfigDir, "*", "agent.json"))
	var out []string
	for _, f := range m {
		if n := filepath.Base(filepath.Dir(f)); ValidInstance(n) == nil {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}
