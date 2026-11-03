package main

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestRepeatedPendingRequestsDoNotAppendAuditWriteOrAlert(t *testing.T) {
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	if err := saveACL(aclFile{Schema: aclSchema, Pending: map[string]string{"account-a": "fixture-time"}}); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(aclPath())
	if err != nil {
		t.Fatal(err)
	}
	var alerts atomic.Int32
	notifications := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { alerts.Add(1); w.WriteHeader(200) }))
	t.Cleanup(notifications.Close)
	t.Setenv("CPC_NOTIFY", notifications.URL)
	for i := 0; i < 3; i++ {
		r := cloudRequest(http.MethodPost, "/request")
		r.Header.Set("Origin", "https://cloud.example")
		w := httptest.NewRecorder()
		cloud(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("idempotent pending request failed: %d", w.Code)
		}
	}
	after, err := os.ReadFile(aclPath())
	if err != nil || !bytes.Equal(before, after) || alerts.Load() != 0 {
		t.Fatal("repeat request changed permissions/audit or sent another alert")
	}
}

func densePendingFixture() aclFile {
	state := aclFile{Schema: aclSchema, Pending: map[string]string{}}
	for i := 0; i < 7000; i++ {
		state.Pending[fmt.Sprintf("Account-%06d", i)] = strings.Repeat("x", 112)
	}
	return state
}

func TestRequestAdmissionReservesCapacityWithoutAcknowledgingOrAlerting(t *testing.T) {
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	state := densePendingFixture()
	if err := saveACL(state); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(aclPath())
	if err != nil {
		t.Fatal(err)
	}
	if len(before) <= maxACLBytes-aclRequestReserve {
		t.Fatal("fixture did not reach reserved capacity")
	}
	var alerts atomic.Int32
	notifications := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { alerts.Add(1); w.WriteHeader(200) }))
	t.Cleanup(notifications.Close)
	t.Setenv("CPC_NOTIFY", notifications.URL)
	r := cloudRequest(http.MethodPost, "/request")
	r.Header.Set("Origin", "https://cloud.example")
	w := httptest.NewRecorder()
	cloud(w, r)
	after, _ := os.ReadFile(aclPath())
	if w.Code != http.StatusServiceUnavailable || !bytes.Equal(before, after) || alerts.Load() != 0 {
		t.Fatal("capacity failure acknowledged, changed state or alerted")
	}
}

func TestAuditCanRollBeforeEntryThresholdWhenEnvelopeWouldExceedLimit(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CPC_ACL", filepath.Join(dir, "acl.json"))
	state := densePendingFixture()
	for i := 0; i < 200; i++ {
		state.record("deny", strings.Repeat("A", 256), strings.Repeat("B", 256))
	}
	if err := saveACL(state); err != nil {
		t.Fatal(err)
	}
	stored, err := loadACL()
	if err != nil {
		t.Fatal(err)
	}
	count, err := verifyAuditHistory(dir, stored.AuditHead)
	if err != nil || count != 200 || len(stored.Audit) != 0 {
		t.Fatal("size-driven rollover did not preserve all entries")
	}
}

func TestAuditRolloverPreservesAllHistoryAndDoesNotBlockRevocation(t *testing.T) {
	cloudOwnerFixture(t)
	state := aclFile{Schema: aclSchema, Approved: []string{"Account-B"}, Pending: map[string]string{}}
	for i := 0; i < 5000; i++ {
		state.record("request", "account-a", "account-a")
	}
	if err := saveACL(state); err != nil {
		t.Fatal(err)
	}
	r := cloudRequest(http.MethodPost, "/deny")
	r.Header.Set("Origin", "https://cloud.example")
	r.Form = map[string][]string{"account_id": {"Account-B"}}
	w := httptest.NewRecorder()
	cloud(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("audit history blocked durable revocation: %d %s", w.Code, w.Body.String())
	}
	stored, err := loadACL()
	if err != nil || len(stored.Approved) != 0 || stored.AuditHead == "" || len(stored.Audit) >= auditSegmentEntries {
		t.Fatal("revocation or audit tail not persisted")
	}
	archived, err := verifyAuditHistory(filepath.Dir(aclPath()), stored.AuditHead)
	if err != nil || archived+len(stored.Audit) != 5001 {
		t.Fatalf("audit history was discarded: archived=%d tail=%d error=%v", archived, len(stored.Audit), err)
	}
}

func TestCorruptArchivedAuditCannotBeExtendedOrSilentlyReplaced(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CPC_ACL", filepath.Join(dir, "acl.json"))
	state := aclFile{Schema: aclSchema, Pending: map[string]string{}}
	for i := 0; i < auditSegmentEntries; i++ {
		state.record("request", "Account-A", "Account-A")
	}
	if err := saveACL(state); err != nil {
		t.Fatal(err)
	}
	stored, err := loadACL()
	if err != nil {
		t.Fatal(err)
	}
	segment := filepath.Join(dir, "audit-segments", stored.AuditHead+".json")
	if err := os.WriteFile(segment, []byte("{broken"), 0600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(aclPath())
	called := false
	if err := mutateACL(func(a *aclFile) { called = true }); err == nil || called {
		t.Fatal("corrupt audit admitted a permission mutation")
	}
	after, _ := os.ReadFile(aclPath())
	if !bytes.Equal(before, after) {
		t.Fatal("corrupt audit evidence was overwritten")
	}
}
