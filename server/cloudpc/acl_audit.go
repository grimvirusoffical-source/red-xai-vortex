package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

const auditSegmentEntries = 256

type aclAuditSegment struct {
	Schema   int        `json:"schema"`
	Previous string     `json:"previous,omitempty"`
	Entries  []aclAudit `json:"entries"`
}

func validAuditDigest(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && hex.EncodeToString(decoded) == value
}

func readAuditSegment(parent, digest string) (aclAuditSegment, error) {
	var segment aclAuditSegment
	if !validAuditDigest(digest) {
		return segment, errors.New("invalid Cloud PC audit reference")
	}
	directory := filepath.Join(parent, "audit-segments")
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return segment, errors.New("Cloud PC audit directory unavailable")
	}
	filename := filepath.Join(directory, digest+".json")
	info, err = os.Lstat(filename)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxACLBytes {
		return segment, errors.New("Cloud PC audit segment unavailable")
	}
	data, err := os.ReadFile(filename)
	if err != nil || len(data) > maxACLBytes {
		return segment, errors.New("Cloud PC audit segment unavailable")
	}
	hash := sha256.Sum256(data)
	if hex.EncodeToString(hash[:]) != digest {
		return segment, errors.New("Cloud PC audit digest mismatch")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&segment); err != nil {
		return segment, errors.New("invalid Cloud PC audit segment")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return segment, errors.New("invalid Cloud PC audit segment")
	}
	if segment.Schema != 1 || len(segment.Entries) < 1 || len(segment.Entries) > auditSegmentEntries || (segment.Previous != "" && !validAuditDigest(segment.Previous)) {
		return segment, errors.New("invalid Cloud PC audit segment")
	}
	return segment, validateACL(aclFile{Schema: aclSchema, Audit: segment.Entries})
}

func verifyAuditHistory(parent, head string) (int, error) {
	seen, count := map[string]bool{}, 0
	for head != "" {
		if seen[head] {
			return count, errors.New("cyclic Cloud PC audit history")
		}
		seen[head] = true
		segment, err := readAuditSegment(parent, head)
		if err != nil {
			return count, err
		}
		count += len(segment.Entries)
		head = segment.Previous
	}
	return count, nil
}

// Persist an immutable, content-addressed segment before the new ACL references
// it. Crashes/failures can leave an unreferenced segment, never discarded history.
func rolloverACLAudit(aclPath string, state aclFile) (aclFile, error) {
	encoded, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return state, err
	}
	force := len(encoded) > maxACLBytes
	if len(state.Audit) < auditSegmentEntries && (!force || len(state.Audit) == 0) {
		return state, nil
	}
	parent := filepath.Dir(aclPath)
	directory := filepath.Join(parent, "audit-segments")
	if err := os.Mkdir(directory, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return state, err
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return state, errors.New("invalid Cloud PC audit directory")
	}
	if err := syncACLDirectory(parent); err != nil {
		return state, err
	}
	for len(state.Audit) >= auditSegmentEntries || (force && len(state.Audit) > 0) {
		count := min(len(state.Audit), auditSegmentEntries)
		segment := aclAuditSegment{Schema: 1, Previous: state.AuditHead, Entries: state.Audit[:count]}
		data, err := json.Marshal(segment)
		if err != nil || len(data) > maxACLBytes {
			return state, errors.New("invalid Cloud PC audit segment")
		}
		hash := sha256.Sum256(data)
		digest := hex.EncodeToString(hash[:])
		filename := filepath.Join(directory, digest+".json")
		file, err := os.OpenFile(filename, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if errors.Is(err, os.ErrExist) {
			// A retry may find the exact unreferenced segment from an uncertain
			// earlier write. Verify and flush it again before acknowledging it.
			if _, verifyErr := readAuditSegment(parent, digest); verifyErr != nil {
				return state, verifyErr
			}
			file, err = os.OpenFile(filename, os.O_RDWR, 0)
		} else if err == nil {
			_, err = file.Write(data)
		}
		if err != nil {
			if file != nil {
				file.Close()
			}
			return state, err
		}
		if err := file.Sync(); err != nil {
			file.Close()
			return state, err
		}
		if err := file.Close(); err != nil {
			return state, err
		}
		if err := syncACLDirectory(directory); err != nil {
			return state, err
		}
		state.AuditHead, state.Audit = digest, state.Audit[count:]
	}
	return state, nil
}
