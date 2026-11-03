package main

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// One Cloud PC gateway owns this file. All in-process read/modify/write
// operations share this lock; it is not a distributed or multi-process lock.
var aclMu sync.Mutex

// Bound to the platform implementation. Package-local injection permits
// isolated persistence-failure tests without changing production paths.
var syncACLParent = syncACLDirectory

const maxACLBytes = 1 << 20
const aclRequestReserve = 128 << 10

const aclSchema = 2

type aclAudit struct {
	At            string `json:"at"`
	Event         string `json:"event"`
	Actor         string `json:"actor_account_id"`
	Target        string `json:"target_account_id"`
	SourceSHA256  string `json:"source_sha256,omitempty"`
	MappingSHA256 string `json:"mapping_sha256,omitempty"`
}

func (a *aclFile) record(event, actor, target string) {
	a.Audit = append(a.Audit, aclAudit{At: time.Now().UTC().Format(time.RFC3339Nano), Event: event, Actor: actor, Target: target})
}

func validateACL(a aclFile) error {
	if a.Schema != aclSchema {
		return errors.New("Cloud PC username permissions require a reviewed account-ID migration")
	}
	if a.AuditHead != "" && !validAuditDigest(a.AuditHead) {
		return errors.New("invalid Cloud PC audit head")
	}
	seen := map[string]bool{}
	for _, id := range a.Approved {
		if !validAccountID(id) || seen[id] {
			return errors.New("invalid Cloud PC account grant")
		}
		seen[id] = true
	}
	for id, stamp := range a.Pending {
		if !validAccountID(id) || len(stamp) == 0 || len(stamp) > 128 {
			return errors.New("invalid Cloud PC account request")
		}
	}
	if len(a.Audit) > 5000 {
		return errors.New("Cloud PC audit retention limit requires protected archival")
	}
	for _, event := range a.Audit {
		if _, err := time.Parse(time.RFC3339Nano, event.At); err != nil || !validAccountID(event.Actor) || !validAccountID(event.Target) {
			return errors.New("invalid Cloud PC permission audit")
		}
		if event.Event != "request" && event.Event != "approve" && event.Event != "deny" && event.Event != "migration" {
			return errors.New("invalid Cloud PC permission audit event")
		}
		if event.Event == "migration" {
			for _, hash := range []string{event.SourceSHA256, event.MappingSHA256} {
				decoded, err := hex.DecodeString(hash)
				if err != nil || len(decoded) != 32 {
					return errors.New("invalid Cloud PC migration audit")
				}
			}
		} else if event.SourceSHA256 != "" || event.MappingSHA256 != "" {
			return errors.New("unexpected Cloud PC audit metadata")
		}
	}
	return nil
}

func loadACL() (aclFile, error) {
	aclMu.Lock()
	defer aclMu.Unlock()
	return readACL(aclPath())
}

func readACL(path string) (aclFile, error) {
	a := aclFile{Schema: aclSchema, Pending: map[string]string{}}
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
	if err := validateACL(a); err != nil {
		return aclFile{}, err
	}
	if a.AuditHead != "" {
		if _, err := readAuditSegment(filepath.Dir(path), a.AuditHead); err != nil {
			return aclFile{}, err
		}
	}
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
	_, err := mutateACLWhen(func(a *aclFile) bool { change(a); return true })
	return err
}

func mutateACLWhen(change func(*aclFile) bool) (bool, error) {
	aclMu.Lock()
	defer aclMu.Unlock()
	path := aclPath()
	a, err := readACL(path)
	if err != nil {
		return false, err
	}
	if !change(&a) {
		return false, nil
	}
	return true, writeACL(path, a)
}

func writeACL(path string, a aclFile) error {
	if err := validateACL(a); err != nil {
		return err
	}
	if _, err := verifyAuditHistory(filepath.Dir(path), a.AuditHead); err != nil {
		return err
	}
	var err error
	a, err = rolloverACLAudit(path, a)
	if err != nil {
		return err
	}
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
