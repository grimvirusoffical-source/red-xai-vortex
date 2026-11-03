package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

var migrationSource = []byte(`{"approved":["Alice"],"pending":{"bob":"fixture-time"}}`)
var migrationMap = []byte(`{"operator_account_id":"Operator-ID","mappings":{"alice":"Account-A","bob":"Account-B"}}`)

func TestExplicitIDMappingPreservesLegacyAssignmentsAndAuditsProvenance(t *testing.T) {
	a, err := mapLegacyACL(migrationSource, migrationMap)
	if err != nil || a.Schema != aclSchema || len(a.Approved) != 1 || a.Approved[0] != "Account-A" || a.Pending["Account-B"] != "fixture-time" || len(a.Audit) != 2 {
		t.Fatalf("explicit mapping did not preserve assignments: %+v %v", a, err)
	}
	for _, audit := range a.Audit {
		if audit.Event != "migration" || audit.Actor != "Operator-ID" || len(audit.SourceSHA256) != 64 || len(audit.MappingSHA256) != 64 {
			t.Fatal("mapping provenance was not recorded")
		}
	}
	for _, bad := range [][]byte{
		[]byte(`{"operator_account_id":"Operator-ID","mappings":{"alice":"Account-A"}}`),
		[]byte(`{"operator_account_id":"Operator-ID","mappings":{"alice":"Account-A","bob":"Account-A"}}`),
		[]byte(`{"operator_account_id":"Operator-ID","mappings":{"alice":"Account-A","bob":"Account-B","extra":"Account-C"}}`),
		[]byte(`{"operator_account_id":"Operator-ID","mappings":{"Alice":"Account-A","bob":"Account-B"}}`),
		[]byte(`{"operator_account_id":"Operator-ID","mappings":{"alice":"Account A","bob":"Account-B"}}`),
		[]byte(`null`), append(append([]byte{}, migrationMap...), []byte(` trailing`)...),
	} {
		if _, err := mapLegacyACL(migrationSource, bad); err == nil {
			t.Fatal("unreviewed/incomplete/colliding mapping accepted")
		}
	}
}

func TestMigrationPreparesNewPrivateFileWithoutTouchingInputsOrLiveACL(t *testing.T) {
	dir := t.TempDir()
	source, mapping := filepath.Join(dir, "legacy-backup.json"), filepath.Join(dir, "private-map.json")
	live, output := filepath.Join(dir, "live-acl.json"), filepath.Join(dir, "review.json")
	t.Setenv("CPC_ACL", live)
	if err := os.WriteFile(source, migrationSource, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mapping, migrationMap, 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--source", source, "--mapping", mapping, "--output", output}
	if err := prepareACLMigration(args); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	var a aclFile
	if err != nil || json.Unmarshal(data, &a) != nil || validateACL(a) != nil {
		t.Fatal("review artifact did not validate")
	}
	if err := prepareACLMigration(args); err == nil {
		t.Fatal("existing review artifact was overwritten")
	}
	if _, err := os.Stat(live); !os.IsNotExist(err) {
		t.Fatal("migration touched live ACL")
	}
	for filename, expected := range map[string][]byte{source: migrationSource, mapping: migrationMap, output: data} {
		actual, err := os.ReadFile(filename)
		if err != nil || !bytes.Equal(actual, expected) {
			t.Fatal("migration changed an input or existing artifact")
		}
	}
	for _, denied := range []string{source, mapping, live} {
		if err := prepareACLMigration([]string{"--source", source, "--mapping", mapping, "--output", denied}); err == nil {
			t.Fatal("migration selected an input/live destination")
		}
	}
}
