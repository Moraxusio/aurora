package entry

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIdentitySurvivesRestartAndNeverReplacesBrokenFiles(t *testing.T) {
	for _, name := range []string{"agent-id", "agent.crt", "agent.key"} {
		for _, remove := range []bool{false, true} {
			t.Run(name+map[bool]string{false: "-broken", true: "-missing"}[remove], func(t *testing.T) {
				dir := t.TempDir()
				_, pin, id, err := loadIdentity(dir)
				if err != nil || id == "" || pin == "" {
					t.Fatalf("initial identity: %q %q %v", pin, id, err)
				}
				_, p, i, err := loadIdentity(dir)
				if err != nil || p != pin || i != id {
					t.Fatalf("restart changed identity: %q %q %v", p, i, err)
				}
				broken := filepath.Join(dir, name)
				if remove {
					err = os.Remove(broken)
				} else {
					err = os.WriteFile(broken, []byte("corrupt fixture"), 0o600)
				}
				if err != nil {
					t.Fatal(err)
				}
				if _, _, _, err := loadIdentity(dir); err == nil {
					t.Fatal("accepted a broken identity")
				}
				b, err := os.ReadFile(broken)
				if (remove && !os.IsNotExist(err)) || (!remove && (err != nil || string(b) != "corrupt fixture")) {
					t.Fatal("startup replaced existing evidence")
				}
			})
		}
	}
}

func TestIdentityDoesNotResetExistingStateMissingEveryIdentityFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "ai"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := loadIdentity(dir); err == nil {
		t.Fatal("existing state misclassified as a fresh install")
	}
	if _, err := os.Stat(filepath.Join(dir, "agent-id")); !os.IsNotExist(err) {
		t.Fatal("startup wrote a new identity")
	}
}
