package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type legacyACL struct {
	Approved []string          `json:"approved"`
	Pending  map[string]string `json:"pending"`
}

type aclIDMapping struct {
	Operator string            `json:"operator_account_id"`
	IDs      map[string]string `json:"mappings"`
}

func decodeMigrationJSON(data []byte, target any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return errors.New("invalid migration input")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return errors.New("trailing migration input")
	}
	return nil
}

// This verifies completeness and collisions, not the provenance of operator
// assertions. It never discovers IDs from names or queries an account service.
func mapLegacyACL(source, mapping []byte) (aclFile, error) {
	var legacy *legacyACL
	var ids *aclIDMapping
	if err := decodeMigrationJSON(source, &legacy); err != nil || legacy == nil {
		return aclFile{}, errors.New("invalid legacy permission snapshot")
	}
	if err := decodeMigrationJSON(mapping, &ids); err != nil || ids == nil || !validAccountID(ids.Operator) {
		return aclFile{}, errors.New("invalid reviewed account-ID mapping")
	}
	names := map[string]bool{}
	for _, name := range legacy.Approved {
		names[strings.ToLower(name)] = true
	}
	for name := range legacy.Pending {
		names[strings.ToLower(name)] = true
	}
	if len(ids.IDs) != len(names) {
		return aclFile{}, errors.New("mapping must cover exactly the legacy names")
	}
	subjects := map[string]string{}
	for name := range names {
		id, exists := ids.IDs[name]
		if name == "" || strings.TrimSpace(name) != name || !exists || !validAccountID(id) {
			return aclFile{}, errors.New("missing or invalid explicit account-ID mapping")
		}
		if prior, exists := subjects[id]; exists && prior != name {
			return aclFile{}, errors.New("mapping would merge distinct legacy users")
		}
		subjects[id] = name
	}
	output := aclFile{Schema: aclSchema, Pending: map[string]string{}}
	approved := map[string]bool{}
	for _, name := range legacy.Approved {
		id := ids.IDs[strings.ToLower(name)]
		if !approved[id] {
			output.Approved = append(output.Approved, id)
			approved[id] = true
		}
	}
	for name, stamp := range legacy.Pending {
		id := ids.IDs[strings.ToLower(name)]
		if prior, exists := output.Pending[id]; exists && prior != stamp {
			return aclFile{}, errors.New("conflicting legacy requests require review")
		}
		output.Pending[id] = stamp
	}
	ordered := make([]string, 0, len(subjects))
	for id := range subjects {
		ordered = append(ordered, id)
	}
	if len(ordered) == 0 {
		ordered = append(ordered, ids.Operator)
	}
	sort.Strings(ordered)
	sourceHash, mappingHash := sha256.Sum256(source), sha256.Sum256(mapping)
	for _, id := range ordered {
		output.record("migration", ids.Operator, id)
		event := &output.Audit[len(output.Audit)-1]
		event.SourceSHA256, event.MappingSHA256 = hex.EncodeToString(sourceHash[:]), hex.EncodeToString(mappingHash[:])
	}
	return output, validateACL(output)
}

func readMigrationFile(filename string, private bool) ([]byte, error) {
	info, err := os.Lstat(filename)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxACLBytes {
		return nil, errors.New("migration requires bounded regular input files")
	}
	if private && os.PathSeparator != '\\' && info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("mapping file must be private (0600)")
	}
	data, err := os.ReadFile(filename)
	if err != nil || len(data) > maxACLBytes {
		return nil, errors.New("could not read migration input")
	}
	return data, nil
}

func prepareACLMigration(args []string) error {
	flags := flag.NewFlagSet("prepare-acl-migration", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	source := flags.String("source", "", "consistent protected legacy ACL backup")
	mapping := flags.String("mapping", "", "private reviewed exact-name to canonical-ID mapping")
	output := flags.String("output", "", "new private review file; never the live ACL")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *source == "" || *mapping == "" || *output == "" {
		return errors.New("use prepare-acl-migration --source BACKUP --mapping PRIVATE_JSON --output NEW_REVIEW_FILE")
	}
	outPath, err := canonicalReviewPath(*output)
	if err != nil {
		return err
	}
	for _, filename := range []string{*source, *mapping, aclPath()} {
		if info, err := os.Lstat(filename); err == nil && info.Mode()&os.ModeSymlink != 0 {
			return errors.New("migration inputs and live ACL must not be symbolic links")
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		inputPath, err := canonicalReviewPath(filename)
		same := inputPath == outPath || (os.PathSeparator == '\\' && strings.EqualFold(inputPath, outPath))
		if err != nil || same {
			return errors.New("migration output must be distinct from inputs and the live ACL")
		}
	}
	snapshot, err := readMigrationFile(*source, false)
	if err != nil {
		return err
	}
	idMap, err := readMigrationFile(*mapping, true)
	if err != nil {
		return err
	}
	prepared, err := mapLegacyACL(snapshot, idMap)
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(prepared, "", "  ")
	if err != nil || len(data) > maxACLBytes-aclRequestReserve {
		return errors.New("prepared ACL exceeds limits")
	}
	file, err := os.OpenFile(outPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return syncACLDirectory(filepath.Dir(outPath))
}

// Resolve parent aliases even when the final file or directory does not exist.
// This prevents an alternate spelling or parent symlink selecting the live ACL.
func canonicalReviewPath(filename string) (string, error) {
	absolute, err := filepath.Abs(filename)
	if err != nil {
		return "", err
	}
	parent, suffix := filepath.Dir(absolute), filepath.Base(absolute)
	for {
		resolved, err := filepath.EvalSymlinks(parent)
		if err == nil {
			return filepath.Join(resolved, suffix), nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		next := filepath.Dir(parent)
		if next == parent {
			return "", err
		}
		suffix = filepath.Join(filepath.Base(parent), suffix)
		parent = next
	}
}
