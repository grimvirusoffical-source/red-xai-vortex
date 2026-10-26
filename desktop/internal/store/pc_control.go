package store

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// Separate from general settings so ordinary settings saves cannot enable it.
type PCControlPolicy struct {
	Version     int  `json:"version"`
	AlwaysAllow bool `json:"alwaysAllow"`
}

func (s *Store) loadPCPolicy() {
	s.pcPolicy = PCControlPolicy{Version: 1}
	f, err := os.Open(s.path("pc-control.json"))
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		s.pcPolicyError = err
		return
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 4097))
	var p PCControlPolicy
	if err != nil || len(data) > 4096 || json.Unmarshal(data, &p) != nil || p.Version != 1 {
		s.pcPolicyError = errors.New("PC control settings could not be read; manual approval remains enabled")
		return
	}
	s.pcPolicy = p
}
func (s *Store) PCPolicy() (PCControlPolicy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pcPolicy, s.pcPolicyError
}
func (s *Store) SetPCPolicy(alwaysAllow bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pcPolicyError != nil {
		return s.pcPolicyError
	}
	p := PCControlPolicy{Version: 1, AlwaysAllow: alwaysAllow}
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(s.Dir, ".pc-control-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(f.Name(), filepath.Join(s.Dir, "pc-control.json")); err != nil {
		return err
	}
	s.pcPolicy = p
	return nil
}

// Absence defaults to manual approval. Unlink revokes the persisted opt-in even
// when a full disk prevents creating a replacement settings file.
func (s *Store) RevokePCPolicy() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pcPolicyError != nil {
		return s.pcPolicyError
	}
	err := os.Remove(s.path("pc-control.json"))
	s.pcPolicy = PCControlPolicy{Version: 1}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if d, e := os.Open(s.Dir); e == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
