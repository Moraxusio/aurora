//go:build linux || windows

package statecrypt

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestStateWriterIsExclusive(t *testing.T) {
	dir := t.TempDir()
	unlock, err := LockWriter(dir)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := LockWriter(dir); err == nil {
		second()
		unlock()
		t.Fatal("second writer admitted")
	}
	if err := CheckNewDir(dir); err != nil {
		t.Fatal(err)
	}
	unlock()
	if again, err := LockWriter(dir); err != nil {
		t.Fatal(err)
	} else {
		again()
	}
}

func TestCloneDirectoryPublishesOnlyCompleteNewDirectories(t *testing.T) {
	base := t.TempDir()
	source, dest := filepath.Join(base, "source"), filepath.Join(base, "dest")
	if err := os.Mkdir(source, 0o700); err != nil {
		t.Fatal(err)
	}
	original := filepath.Join(source, "original")
	if err := os.WriteFile(original, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	fault := errors.New("synthetic publication interruption")
	if err := CloneDirectory(source, dest, func(stage string, _ []string) error {
		if err := os.WriteFile(filepath.Join(stage, "evidence"), []byte("synthetic"), 0o600); err != nil {
			return err
		}
		return fault
	}); !errors.Is(err, fault) {
		t.Fatal(err)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("partial destination was published")
	}
	write := func(stage string, files []string) error {
		if len(files) != 1 || files[0] != "original" {
			return errors.New("incorrect source listing")
		}
		return os.WriteFile(filepath.Join(stage, "result"), []byte("complete"), 0o600)
	}
	if err := CloneDirectory(source, filepath.Join(source, "nested"), write); err == nil {
		t.Fatal("allowed a destination inside the source")
	}
	release, err := LockWriter(source)
	if err != nil {
		t.Fatal(err)
	}
	if err := CloneDirectory(source, dest, write); err == nil {
		release()
		t.Fatal("allowed a clone while the source writer was active")
	}
	release()
	if err := os.Remove(filepath.Join(source, WriterFile)); err != nil {
		t.Fatal(err)
	}
	if err := CloneDirectory(source, dest, write); err != nil {
		t.Fatal(err)
	}
	if err := CloneDirectory(source, dest, write); err == nil {
		t.Fatal("overwrote an existing destination")
	}
	if b, err := os.ReadFile(original); err != nil || string(b) != "original" {
		t.Fatal("source changed")
	}
}
