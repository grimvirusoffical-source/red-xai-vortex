package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func auditFixture(t *testing.T) *auditStore { t.Helper(); return &auditStore{Dir: t.TempDir()} }
func addAudit(t *testing.T, s *auditStore, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if err := s.append(map[string]any{"t": i, "action": "fixture"}); err != nil {
			t.Fatal(err)
		}
	}
}
func auditSelect(events []map[string]any) map[string]bool {
	m := map[string]bool{}
	for _, e := range events {
		m[e["id"].(string)] = true
	}
	return m
}
func TestAuditRetentionBacksUpLegacyBeforeTrimming(t *testing.T) {
	s := auditFixture(t)
	var old bytes.Buffer
	for i := 0; i < 23; i++ {
		_ = json.NewEncoder(&old).Encode(map[string]any{"t": i, "action": "legacy"})
	}
	path := filepath.Join(s.Dir, "audit.jsonl")
	if err := os.WriteFile(path, old.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	events, err := s.list()
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 10 || events[0]["t"] != float64(22) || events[9]["t"] != float64(13) {
		t.Fatalf("unexpected retention: %#v", events)
	}
	copies, _ := filepath.Glob(filepath.Join(s.Dir, "audit-before-retention-*.jsonl"))
	if len(copies) != 1 {
		t.Fatalf("missing migration backup %v", copies)
	}
	saved, _ := os.ReadFile(copies[0])
	if !bytes.Equal(saved, old.Bytes()) {
		t.Fatal("legacy backup changed")
	}
	info, _ := os.Stat(copies[0])
	if info.Mode().Perm() != 0600 {
		t.Fatal("backup not private")
	}
	firstID := events[0]["id"]
	reopened := &auditStore{Dir: s.Dir}
	events, err = reopened.list()
	if err != nil || events[0]["id"] != firstID {
		t.Fatal("IDs not stable after restart")
	}
	addAudit(t, reopened, 1)
	events, _ = reopened.list()
	if len(events) != 10 {
		t.Fatal("retention exceeded")
	}
	copies, _ = filepath.Glob(filepath.Join(s.Dir, "audit-before-retention-*.jsonl"))
	if len(copies) != 1 {
		t.Fatal("normal retention made repeated backups")
	}
}
func TestAuditExportSaveConfirmationPreservesNewEvents(t *testing.T) {
	s := auditFixture(t)
	addAudit(t, s, 5)
	events, _ := s.list()
	ids := auditSelect(events)
	snapshot, err := s.prepareExport(ids, "owner", "device")
	if err != nil {
		t.Fatal(err)
	}
	token := snapshot["snapshotToken"].(string)
	if got, _ := s.list(); len(got) != 5 {
		t.Fatal("export deleted before save")
	}
	if _, err = s.confirmExport(token, "owner", "device", false); err == nil {
		t.Fatal("unsaved confirmation allowed")
	}
	if _, err = s.confirmExport(token, "other", "device", true); err == nil {
		t.Fatal("other caller allowed")
	}
	if _, err = s.confirmExport(token, "owner", "other", true); err == nil {
		t.Fatal("other device allowed")
	}
	addAudit(t, s, 2)
	removed, err := s.confirmExport(token, "owner", "device", true)
	if err != nil || removed != 5 {
		t.Fatalf("clear: %d %v", removed, err)
	}
	remaining, _ := s.list()
	if len(remaining) != 2 {
		t.Fatal("new events removed")
	}
	for _, e := range remaining {
		if ids[e["id"].(string)] {
			t.Fatal("exported event retained")
		}
	}
	if _, err = s.confirmExport(token, "owner", "device", true); err == nil {
		t.Fatal("confirmation replay allowed")
	}
	if len(snapshot["events"].([]map[string]any)) != 5 {
		t.Fatal("snapshot mutated")
	}
}
func TestAuditClearPreservesConcurrentAppend(t *testing.T) {
	s := auditFixture(t)
	addAudit(t, s, 3)
	events, _ := s.list()
	ids := auditSelect(events)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 4; i++ {
			if err := s.append(map[string]any{"action": "concurrent"}); err != nil {
				t.Error(err)
			}
		}
	}()
	go func() {
		defer wg.Done()
		if _, err := s.clear(ids); err != nil {
			t.Error(err)
		}
	}()
	wg.Wait()
	events, _ = s.list()
	if len(events) != 4 {
		t.Fatalf("new events lost: %d", len(events))
	}
}
func TestAuditCorruptHistoryAndFailedWritesPreserveData(t *testing.T) {
	s := auditFixture(t)
	path := filepath.Join(s.Dir, "audit.jsonl")
	original := []byte("invalid legacy record\n")
	os.WriteFile(path, original, 0600)
	if err := s.append(map[string]any{"action": "new"}); err == nil {
		t.Fatal("corrupt history overwritten")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(after, original) {
		t.Fatal("original history lost")
	}
	good := auditFixture(t)
	addAudit(t, good, 1)
	before, _ := good.list()
	good.Dir = filepath.Join(good.Dir, "missing")
	if _, err := good.clear(auditSelect(before)); err == nil {
		t.Fatal("failed disk clear reported success")
	}
	afterEvents, _ := good.list()
	if len(afterEvents) != 1 {
		t.Fatal("failed write changed memory")
	}
}
func TestAuditEndpointsRequireAdminAndOwnerUnlock(t *testing.T) {
	prior := ownerAudit
	ownerAudit = auditFixture(t)
	defer func() { ownerAudit = prior }()
	ownerMu.Lock()
	oldPHC, oldToks := ownerPHC, ownerToks
	ownerPHC = "fixture-not-a-password"
	ownerToks = map[string]int64{}
	ownerMu.Unlock()
	defer func() { ownerMu.Lock(); ownerPHC, ownerToks = oldPHC, oldToks; ownerMu.Unlock() }()
	for _, caller := range []*Key{nil, {ID: "regular", Admin: false}, {ID: "admin", Admin: true}} {
		req := httptest.NewRequest("POST", "/admin/audit/clear", strings.NewReader(`{"ids":[]}`))
		w := httptest.NewRecorder()
		handleAuditAdmin(w, req, req.URL.Path, caller)
		if w.Code != 401 {
			t.Fatalf("auth allowed %#v: %d", caller, w.Code)
		}
	}
	device := strings.Repeat("a", 64)
	ownerMu.Lock()
	ownerToks[device] = time.Now().Add(time.Minute).Unix()
	ownerMu.Unlock()
	req := httptest.NewRequest("POST", "/admin/audit/clear", strings.NewReader(`{"ids":[]}`))
	req.Header.Set("X-Vortex-Device", device)
	w := httptest.NewRecorder()
	handleAuditAdmin(w, req, req.URL.Path, &Key{ID: "fixture-admin", Admin: true})
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	req = httptest.NewRequest("POST", "/admin/audit/clear", strings.NewReader(`{"all":true}`))
	req.Header.Set("X-Vortex-Device", device)
	w = httptest.NewRecorder()
	handleAuditAdmin(w, req, req.URL.Path, &Key{ID: "fixture-admin", Admin: true})
	if w.Code != 400 {
		t.Fatal("unbounded clear allowed")
	}
	ownerMu.Lock()
	oldBans := bans
	bans.Devices = append([]string{}, device)
	ownerMu.Unlock()
	defer func() { ownerMu.Lock(); bans = oldBans; ownerMu.Unlock() }()
	req = httptest.NewRequest("POST", "/admin/audit/clear", strings.NewReader(`{"ids":[]}`))
	req.Header.Set("X-Vortex-Device", device)
	w = httptest.NewRecorder()
	handleAuditAdmin(w, req, req.URL.Path, &Key{ID: "fixture-admin", Admin: true})
	if w.Code != 403 {
		t.Fatal("banned unlocked device allowed", w.Code)
	}

}
func TestAuditAdminHTTPKeepsExistingAuthenticationBoundary(t *testing.T) {
	previous := ownerAudit
	ownerAudit = auditFixture(t)
	defer func() { ownerAudit = previous }()
	aclMu.Lock()
	oldACL := acl
	acl = ACL{}
	aclMu.Unlock()
	defer func() { aclMu.Lock(); acl = oldACL; aclMu.Unlock() }()
	mu.Lock()
	oldKeys, oldPepper := keys, pepper
	pepper = []byte("isolated-test-pepper")
	plain := "redx_ai_regular_test_fixture"
	keys = []*Key{{ID: "fixture-regular", Hash: hashKey(plain), Admin: false}}
	mu.Unlock()
	defer func() { mu.Lock(); keys, pepper = oldKeys, oldPepper; mu.Unlock() }()
	for _, credential := range []string{"", plain} {
		req := httptest.NewRequest("POST", "/admin/audit/clear", strings.NewReader(`{"ids":[]}`))
		if credential != "" {
			req.Header.Set("Authorization", "Bearer "+credential)
		}
		w := httptest.NewRecorder()
		adminHandler(w, req)
		if w.Code != 401 {
			t.Fatalf("non-admin HTTP request allowed: %d", w.Code)
		}
	}
}
func TestAuditExportExpirationPreservesRecords(t *testing.T) {
	s := auditFixture(t)
	addAudit(t, s, 2)
	events, _ := s.list()
	snapshot, err := s.prepareExport(auditSelect(events), "owner", "device")
	if err != nil {
		t.Fatal(err)
	}
	token := snapshot["snapshotToken"].(string)
	s.mu.Lock()
	pending := s.exports[token]
	pending.Expires = time.Now().Add(-time.Second)
	s.exports[token] = pending
	s.mu.Unlock()
	if _, err = s.confirmExport(token, "owner", "device", true); err == nil {
		t.Fatal("expired confirmation accepted")
	}
	remaining, _ := s.list()
	if len(remaining) != 2 {
		t.Fatal("expired export deleted records")
	}
}
