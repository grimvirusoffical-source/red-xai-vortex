package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func accountBrokerFixture(t *testing.T) *Server {
	t.Helper()
	root := t.TempDir()
	s := &Server{St: store.OpenAt(filepath.Join(root, "SignedOut")), installationDir: root, accountBroker: true}
	t.Cleanup(s.clearAccountWorkspace)
	return s
}
func profileRequest(s *Server, lease, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", "http://127.0.0.1:43210/bridge/"+path, strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:12345"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "http://127.0.0.1:43210")
	if lease != "" {
		req.Header.Set("X-Vortex-Profile", lease)
	}
	out := httptest.NewRecorder()
	s.handle(out, req)
	return out
}
func TestAccountWorkspaceRequiresVerifiedIdentityAndLease(t *testing.T) {
	s := accountBrokerFixture(t)
	if w := profileRequest(s, "", "status", "{}"); w.Code != 401 {
		t.Fatalf("anonymous workspace: %d", w.Code)
	}
	if err := s.activateAccount("rxa_a", "A", "", time.Now().Add(time.Hour), s.accountEpoch()); err != nil {
		t.Fatal(err)
	}
	a := s.accounts.workspace
	a.St.SaveChat(store.Chat{ID: "private", Title: "Private A", Messages: []store.Msg{{Role: "user", Content: "account-A-only"}}})
	if w := profileRequest(s, "", "chat.get", `{"id":"private"}`); w.Code != 401 {
		t.Fatalf("missing lease: %d", w.Code)
	}
	if w := profileRequest(s, a.profileLease, "chat.get", `{"id":"private"}`); w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte("account-A-only")) {
		t.Fatalf("A could not access own data: %s", w.Body.String())
	}
	if err := a.saveCredential("agent-key-shared-id", "A-key-fixture"); err != nil {
		t.Fatal(err)
	}
	s.clearAccountWorkspace()
	if a.credential("agent-key-shared-id") != "" {
		t.Fatal("signed-out runtime still returns credentials")
	}
	if err := s.activateAccount("rxa_b", "B", "", time.Now().Add(time.Hour), s.accountEpoch()); err != nil {
		t.Fatal(err)
	}
	b := s.accounts.workspace
	if a.St.Dir == b.St.Dir || a.profileLease == b.profileLease {
		t.Fatal("profile namespaces overlap")
	}
	if b.credential("agent-key-shared-id") != "" {
		t.Fatal("B inherited A's provider credential")
	}
	if w := profileRequest(s, a.profileLease, "chat.get", `{"id":"private"}`); w.Code != 401 {
		t.Fatalf("stale A lease accepted for B: %d", w.Code)
	}
	if w := profileRequest(s, b.profileLease, "chat.get", `{"id":"private"}`); bytes.Contains(w.Body.Bytes(), []byte("account-A-only")) {
		t.Fatal("B saw A's chat")
	}
	s.clearAccountWorkspace()
	if err := s.activateAccount("rxa_a", "A", "", time.Now().Add(time.Hour), s.accountEpoch()); err != nil {
		t.Fatal(err)
	}
	if s.accounts.workspace.credential("agent-key-shared-id") != "A-key-fixture" {
		t.Fatal("A's saved credential was not preserved")
	}
	_ = s.accounts.workspace.saveCredential("agent-key-shared-id", "")
}
func TestLogoutRejectsLateAuthenticationAndStopsOwnedRuns(t *testing.T) {
	s := accountBrokerFixture(t)
	epoch := s.accountEpoch()
	if err := s.activateAccount("rxa_a", "A", "", time.Now().Add(time.Hour), epoch); err != nil {
		t.Fatal(err)
	}
	a := s.accounts.workspace
	ctx, cancel := context.WithCancel(context.Background())
	run := &Run{ID: "account-bound-fixture", server: a, cancel: cancel, Started: time.Now(), pcRun: true}
	a.registerPCRun(run)
	t.Cleanup(func() { runs.mu.Lock(); delete(runs.runs, run.ID); runs.mu.Unlock() })
	s.clearAccountWorkspace()
	if ctx.Err() == nil {
		t.Fatal("logout did not cancel the old run")
	}
	if err := s.activateAccount("rxa_a", "A", "", time.Now().Add(time.Hour), epoch); err == nil {
		t.Fatal("stale sign-in resurrected a logged-out account")
	}
}
func TestRunListingAndStopAreBoundToAccountRuntime(t *testing.T) {
	a := workspaceServer(t)
	b := workspaceServer(t)
	_, cancel := context.WithCancel(context.Background())
	defer cancel()
	run := &Run{ID: "run-isolation-fixture", server: a, cancel: cancel}
	runs.mu.Lock()
	runs.runs[run.ID] = run
	runs.mu.Unlock()
	defer func() { runs.mu.Lock(); delete(runs.runs, run.ID); runs.mu.Unlock() }()
	if len(b.listRuns()) != 0 {
		t.Fatal("B listed A's run")
	}
	if b.stopRun(run.ID)["ok"] == true {
		t.Fatal("B stopped A's run")
	}
	if len(a.listRuns()) == 0 {
		t.Fatal("A cannot see its own run")
	}
}
func TestLegacyWorkspaceIsNotAssignedToFirstLogin(t *testing.T) {
	s := accountBrokerFixture(t)
	legacy := filepath.Join(s.rootDirectory(), "agents.json")
	if err := os.WriteFile(legacy, []byte(`[{"id":"owner-private"}]`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.activateAccount("rxa_new", "New account", "", time.Now().Add(time.Hour), s.accountEpoch()); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(s.accounts.workspace.St.AgentsSnapshot())
	if bytes.Contains(data, []byte("owner-private")) {
		t.Fatal("unverified legacy data adopted by new account")
	}
	if _, err := os.Stat(legacy); err != nil {
		t.Fatal("legacy data was deleted")
	}
}

func TestMediaCacheIsScopedToWorkspace(t *testing.T) {
	a := &Server{St: store.OpenAt(t.TempDir())}
	b := &Server{St: store.OpenAt(t.TempDir())}
	a.saveRec(&mediaRec{ID: "same-job", Status: "done", Spec: MediaSpec{Prompt: "A private prompt"}})
	if b.mediaRec("same-job") != nil {
		t.Fatal("account B received account A media cache")
	}
	b.saveRec(&mediaRec{ID: "same-job", Status: "done", Spec: MediaSpec{Prompt: "B private prompt"}})
	if a.mediaRec("same-job").Spec.Prompt != "A private prompt" {
		t.Fatal("B overwrote A media cache")
	}
}
