package update

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Failed targets are remembered independently of the rolled-back binary.
type Failure struct {
	Version string `json:"version"`
	Message string `json:"message"`
}

func FailureFor(stateDir, version string) (bool, error) {
	b, err := os.ReadFile(filepath.Join(stateDir, "failed-upgrades.json"))
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var fs []Failure
	if err = json.Unmarshal(b, &fs); err != nil {
		return false, err
	}
	for _, f := range fs {
		if f.Version == version {
			return true, nil
		}
	}
	return false, nil
}
func RecordFailure(stateDir string, f Failure) error {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return err
	}
	p := filepath.Join(stateDir, "failed-upgrades.json")
	var fs []Failure
	if b, err := os.ReadFile(p); err == nil {
		if err = json.Unmarshal(b, &fs); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	for _, v := range fs {
		if v.Version == f.Version {
			return nil
		}
	}
	fs = append(fs, f)
	b, err := json.Marshal(fs)
	if err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err = os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}
