package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// One Cloud PC gateway owns this file. All in-process read/modify/write
// operations share this lock; it is not a distributed or multi-process lock.
var aclMu sync.Mutex

// Bound to the platform implementation. Package-local injection permits
// isolated persistence-failure tests without changing production paths.
var syncACLParent = syncACLDirectory

const maxACLBytes = 1 << 20

func loadACL() (aclFile, error) {
	aclMu.Lock()
	defer aclMu.Unlock()
	return readACL(aclPath())
}

func readACL(path string) (aclFile, error) {
	a := aclFile{Pending: map[string]string{}}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return a, nil
	}
	if err != nil {
		return a, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxACLBytes {
		return a, errors.New("invalid Cloud PC permission file")
	}
	f, err := os.Open(path)
	if err != nil {
		return a, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, maxACLBytes+1))
	d.DisallowUnknownFields()
	var decoded *aclFile
	if err := d.Decode(&decoded); err != nil {
		return a, fmt.Errorf("decode Cloud PC permissions: %w", err)
	}
	if decoded == nil {
		return a, errors.New("null Cloud PC permissions")
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return a, errors.New("trailing Cloud PC permission data")
	}
	a = *decoded
	if a.Pending == nil {
		a.Pending = map[string]string{}
	}
	return a, nil
}

func saveACL(a aclFile) error {
	aclMu.Lock()
	defer aclMu.Unlock()
	return writeACL(aclPath(), a)
}

func mutateACL(change func(*aclFile)) error {
	aclMu.Lock()
	defer aclMu.Unlock()
	path := aclPath()
	a, err := readACL(path)
	if err != nil {
		return err
	}
	change(&a)
	return writeACL(path, a)
}

func writeACL(path string, a aclFile) error {
	data, err := json.MarshalIndent(a, "", "  ")
	if err != nil {
		return err
	}
	if len(data) > maxACLBytes {
		return errors.New("Cloud PC permissions exceed file limit")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0750); err != nil {
		return err
	}
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return errors.New("invalid Cloud PC permission file")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	f, err := os.CreateTemp(dir, ".cloudpc-acl-*.tmp")
	if err != nil {
		return err
	}
	temporary := f.Name()
	defer os.Remove(temporary)
	defer f.Close()
	if err := f.Chmod(0640); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	// A rename succeeding is not enough to acknowledge a durable revoke.
	// Failure here returns an error even when the new file is already visible.
	return syncACLParent(dir)
}
