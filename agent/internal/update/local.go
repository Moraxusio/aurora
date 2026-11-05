package update

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Paths struct {
	InstallDir string
	DataDir    string
}

func DefaultPaths() (Paths, error) {
	root := os.Getenv("LOCALAPPDATA")
	if root == "" {
		return Paths{}, errors.New("LOCALAPPDATA is empty")
	}
	return Paths{InstallDir: filepath.Join(root, "Programs", "Aurora"), DataDir: filepath.Join(root, "Aurora")}, nil
}

func (p Paths) StateDir() string { return filepath.Join(p.DataDir, "update") }
func sanitizeVersion(v string) string {
	var b strings.Builder
	for _, r := range v {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}
func (p Paths) StartedMarker(version string) string {
	return filepath.Join(p.StateDir(), "started-"+sanitizeVersion(version))
}
func (p Paths) LastResultFile() string { return filepath.Join(p.StateDir(), "last-result.json") }
func (p Paths) DownloadDir(version string) string {
	return filepath.Join(p.DataDir, "updates", sanitizeVersion(version))
}
func (p Paths) SetupCopy() string { return filepath.Join(p.DataDir, "setup", "aurora-setup.exe") }

type LastResult struct {
	Version string `json:"version"`
	From    string `json:"from"`
	OK      bool   `json:"ok"`
	Error   string `json:"error"`
	Time    int64  `json:"time"`
}

func WriteLastResult(p Paths, r LastResult) error {
	if err := os.MkdirAll(p.StateDir(), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(p.StateDir(), ".last-result-")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	if e := f.Close(); err == nil {
		err = e
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, p.LastResultFile())
}
func ReadLastResult(p Paths) (LastResult, bool, error) {
	b, err := os.ReadFile(p.LastResultFile())
	if os.IsNotExist(err) {
		return LastResult{}, false, nil
	}
	if err != nil {
		return LastResult{}, false, err
	}
	var r LastResult
	if err := json.Unmarshal(b, &r); err != nil {
		return LastResult{}, false, err
	}
	return r, true, nil
}
