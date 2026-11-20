//go:build linux || windows

package activation

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"aurora3/internal/statecrypt"
)

var oldProgram = Program{Version: "4.0.0", SHA256: strings.Repeat("a", 64)}
var newProgram = Program{Version: "4.0.1", SHA256: strings.Repeat("b", 64)}

func fixtureVerifier(p Program) error {
	if p != oldProgram && p != newProgram {
		return errors.New("unknown program")
	}
	return nil
}

func TestInterruptedTrialKeepsLastConfirmedProgram(t *testing.T) {
	if dir := os.Getenv("AURORA_ACTIVATION_FIXTURE"); dir != "" {
		s := &Store{Dir: dir, Verify: fixtureVerifier}
		_, _ = s.Trial(oldProgram, newProgram, func(Program) error {
			os.Exit(23)
			return nil
		})
		t.Fatal("trial did not start")
	}
	dir := t.TempDir()
	s := &Store{Dir: dir, Verify: fixtureVerifier}
	if err := s.Initialize(oldProgram); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestInterruptedTrialKeepsLastConfirmedProgram$")
	cmd.Env = append(os.Environ(), "AURORA_ACTIVATION_FIXTURE="+dir)
	b, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 23 {
		t.Fatalf("trial was not interrupted: %v %s", err, b)
	}
	status, err := s.ReadReceipt()
	if err != nil || status.Active != oldProgram || status.Receipt == nil || status.Receipt.State != "trying" {
		t.Fatal("trial was not persisted apart from the confirmed pointer", err)
	}
	for range 2 {
		p, err := s.SelectOnBoot()
		if err != nil || p != oldProgram {
			t.Fatalf("unconfirmed program selected: %+v %v", p, err)
		}
	}
	end, err := s.ReadReceipt()
	if err != nil || end.Receipt.ID != status.Receipt.ID || end.Receipt.State != "abandoned" {
		t.Fatal("restart lost the original receipt")
	}
	if _, err := s.Trial(oldProgram, newProgram, func(Program) error {
		t.Fatal("replayed a lost response")
		return nil
	}); err == nil {
		t.Fatal("accepted a repeated version")
	}
}

func TestTrialReceiptAfterUncertainPublish(t *testing.T) {
	for _, tookEffect := range []bool{false, true} {
		name := "before-rename"
		if tookEffect {
			name = "after-rename"
		}
		t.Run(name, func(t *testing.T) {
			s := &Store{Dir: t.TempDir(), Verify: fixtureVerifier}
			if err := s.Initialize(oldProgram); err != nil {
				t.Fatal(err)
			}
			writes := 0
			s.save = func(stage, final string) error {
				writes++
				if writes == 1 || tookEffect {
					if err := statecrypt.ReplaceFile(stage, final); err != nil {
						return err
					}
				}
				if writes == 2 {
					return errors.New("simulated storage error")
				}
				return nil
			}
			job, err := s.Trial(oldProgram, newProgram, func(Program) error { return nil })
			if err == nil {
				t.Fatal("lost persistence acknowledgement was reported as success")
			}
			status, err := s.ReadReceipt()
			if err != nil || status.Receipt.ID != job.ID || (status.Active == newProgram) != tookEffect {
				t.Fatalf("receipt and pointer disagree: %+v %v", status, err)
			}
			s.save = nil
			p, err := s.SelectOnBoot()
			if err != nil || p != status.Active {
				t.Fatalf("boot did not honor durable selection: %v %v", p, err)
			}
		})
	}
}

func TestBootRefusesInadmissibleActiveAndDamagedRecord(t *testing.T) {
	s := &Store{Dir: t.TempDir(), Verify: fixtureVerifier}
	if err := s.Initialize(oldProgram); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Trial(oldProgram, newProgram, func(Program) error { return nil }); err != nil {
		t.Fatal(err)
	}
	s.Verify = func(p Program) error {
		if p == newProgram {
			return errors.New("revoked by fixture policy")
		}
		return nil
	}
	if _, err := s.SelectOnBoot(); err == nil {
		t.Fatal("boot silently chose a different generation")
	}
	path := filepath.Join(s.Dir, selectionName)
	damage := []byte(`{"format":1,"active":`)
	if err := os.WriteFile(path, damage, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Initialize(oldProgram); err == nil {
		t.Fatal("initialization overwrote unreadable selection")
	}
	if b, err := os.ReadFile(path); err != nil || string(b) != string(damage) {
		t.Fatal("unreadable selection changed")
	}
}
