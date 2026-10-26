package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPCControlPolicyDefaultsOffPersistsAndPreservesCorruptFiles(t *testing.T) {
	dir := t.TempDir()
	s := OpenAt(dir)
	p, err := s.PCPolicy()
	if err != nil || p.AlwaysAllow {
		t.Fatal("default policy must ask")
	}
	if err = s.SetPCPolicy(true); err != nil {
		t.Fatal(err)
	}
	s = OpenAt(dir)
	p, err = s.PCPolicy()
	if err != nil || !p.AlwaysAllow {
		t.Fatal("explicit policy did not persist")
	}
	if err = s.SetPCPolicy(false); err != nil {
		t.Fatal(err)
	}
	p, _ = OpenAt(dir).PCPolicy()
	if p.AlwaysAllow {
		t.Fatal("manual mode did not persist")
	}
	if err = s.SetPCPolicy(true); err != nil {
		t.Fatal(err)
	}
	if err = s.RevokePCPolicy(); err != nil {
		t.Fatal(err)
	}
	p, _ = OpenAt(dir).PCPolicy()
	if p.AlwaysAllow {
		t.Fatal("revocation did not survive restart")
	}
	path := filepath.Join(dir, "pc-control.json")
	data := []byte(`{"version":2,"alwaysAllow":true}`)
	os.WriteFile(path, data, 0600)
	s = OpenAt(dir)
	p, err = s.PCPolicy()
	if err == nil || p.AlwaysAllow {
		t.Fatal("unknown policy did not fail closed")
	}
	if s.SetPCPolicy(true) == nil {
		t.Fatal("unknown future policy overwritten")
	}
	saved, _ := os.ReadFile(path)
	if string(saved) != string(data) {
		t.Fatal("future settings lost")
	}
}
