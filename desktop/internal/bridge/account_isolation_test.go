package bridge

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	oskeyring "github.com/zalando/go-keyring"
)

func init() { oskeyring.MockInit() } // Test binary only: never use the developer's real OS credential store.

func TestVerifiedAccountsHaveIndependentStoresSecretsAndRuns(t *testing.T) {
	root := workspaceServer(t)
	root.baseCredential = nil
	a, e := root.activateVerifiedAccount("alice", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	a.St.SaveAgent(store.Agent{ID: "alice-private", Name: "Private Alice agent"})
	if e = a.secretSet("vortex-api-key", "alice-fixture-key"); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runs.mu.Lock()
	runs.runs["account-fixture-a"] = &Run{ID: "account-fixture-a", server: a, cancel: cancel}
	runs.mu.Unlock()
	t.Cleanup(func() { runs.mu.Lock(); delete(runs.runs, "account-fixture-a"); runs.mu.Unlock(); root.lockAccount() })
	root.lockAccount()
	select {
	case <-ctx.Done():
	default:
		t.Fatal("logout failed to cancel old account task")
	}
	b, e := root.activateVerifiedAccount("bob", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	if a.St.Dir == b.St.Dir || a.profileToken == b.profileToken {
		t.Fatal("profiles or request epochs were shared")
	}
	for _, v := range b.St.AgentsSnapshot() {
		if v.ID == "alice-private" {
			t.Fatal("Alice agent leaked to Bob")
		}
	}
	if b.secretGet("vortex-api-key") != "" {
		t.Fatal("Alice credential leaked to Bob")
	}
	if len(b.listOwnRuns()) != 0 {
		t.Fatal("Alice run leaked to Bob")
	}
	if b.stopRun("account-fixture-a")["ok"] == true {
		t.Fatal("Bob stopped Alice run")
	}
	a.St.SaveChat(store.Chat{ID: "late-alice", Title: "Late result"})
	if len(b.St.Chats) != 0 {
		t.Fatal("late result crossed account boundary")
	}
	again, e := root.activateVerifiedAccount("alice", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	found := false
	for _, v := range again.St.AgentsSnapshot() {
		if v.ID == "alice-private" {
			found = true
		}
	}
	if !found || again.secretGet("vortex-api-key") != "alice-fixture-key" {
		t.Fatal("Alice data was not preserved")
	}
	if _, e = os.Stat(filepath.Join(root.St.Dir, "secrets", a.secretName("vortex-api-key"))); !os.IsNotExist(e) {
		t.Fatal("credential was written as plaintext")
	}
}

func profileRequest(root *Server, scope, method string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "http://127.0.0.1:11774/bridge/"+method, strings.NewReader(`{}`))
	r.RemoteAddr = "127.0.0.1:24000"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "http://127.0.0.1:11774")
	r.Header.Set("X-Vortex-Profile", scope)
	w := httptest.NewRecorder()
	root.handle(w, r)
	return w
}
func TestStaleTabsCannotReadOrMutateANewAccount(t *testing.T) {
	root := workspaceServer(t)
	root.baseCredential = nil
	a, e := root.activateVerifiedAccount("alice-http", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	b, e := root.activateVerifiedAccount("bob-http", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	root.accountIsolation = true
	t.Cleanup(root.lockAccount)
	for _, m := range []string{"chat.new", "run.list", "settings.save", "mcp.list", "pcControl.status"} {
		w := profileRequest(root, a.profileToken, m)
		if w.Code != http.StatusConflict {
			t.Fatalf("stale %s returned %d", m, w.Code)
		}
	}
	w := profileRequest(root, b.profileToken, "mcp.list")
	if w.Code != 200 {
		t.Fatalf("current account rejected: %d %s", w.Code, w.Body.String())
	}
	var response map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &response)
	if response["ok"] != true {
		t.Fatal(response)
	}
	if len(b.St.Chats) != 0 {
		t.Fatal("stale account mutation executed")
	}
}
func TestProfileCannotBeChosenByDisplayNameOrAnUnverifiedSelector(t *testing.T) {
	a, _ := accountProfileID("a")
	b, _ := accountProfileID("b")
	if a == b || len(a) != 64 {
		t.Fatal("bad account identity")
	}
	for _, value := range []string{"", " ", "bad\nsubject"} {
		if _, e := accountProfileID(value); e == nil {
			t.Fatal("invalid subject accepted")
		}
	}
	root := workspaceServer(t)
	root.baseCredential = nil
	epoch := root.accountEpoch()
	root.lockAccount()
	if _, e := root.activateVerifiedAccount("late-sign-in", "", time.Now().Add(time.Hour), epoch); e == nil {
		t.Fatal("late login resurrected signed-out profile")
	}
}

func TestMediaCacheDoesNotCrossAccountBoundaries(t *testing.T) {
	root := workspaceServer(t)
	root.baseCredential = nil
	a, e := root.activateVerifiedAccount("media-alice", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	a.saveRec(&mediaRec{ID: "shared-job-name", Status: "done", Spec: MediaSpec{Prompt: "Alice private prompt"}})
	b, e := root.activateVerifiedAccount("media-bob", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	defer root.lockAccount()
	if b.mediaRec("shared-job-name") != nil {
		t.Fatal("media cache leaked another account’s record")
	}
	if a.mediaRec("shared-job-name") == nil {
		t.Fatal("original account’s record was removed")
	}
}
