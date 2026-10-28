package bridge

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestSavedOwnerCredentialNeverBypassesAccountSignIn(t *testing.T) {
	s := workspaceServer(t)
	s.baseCredential = func(string) string { return "test-only-owner-credential" }
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer admin.Close()
	t.Setenv("VORTEX_ADMIN_BASE", admin.URL)
	if err := s.setAccountSwitchRequired(true); err != nil {
		t.Fatal(err)
	}
	gate := s.redx("gate.status", nil)
	if gate["owner"] == true || gate["ownerAvailable"] == true || gate["signedIn"] == true {
		t.Fatal("owner credential bypassed login")
	}
	if s.redx("redx.owner.continue", nil)["ok"] == true {
		t.Fatal("owner shortcut bypassed login")
	}
	if _, err := os.Stat(s.accountSwitchPath()); err != nil {
		t.Fatal("owner shortcut cleared sign-out marker")
	}
}

func TestDesktopAccountControlRejectsCrossOriginAndRemoteRequests(t *testing.T) {
	s := workspaceServer(t)
	for _, method := range []string{"redx.logout", "redx.owner.continue"} {
		for _, remote := range []string{"203.0.113.7:2222", "127.0.0.1:2345"} {
			req := httptest.NewRequest("POST", "http://127.0.0.1:11774/bridge/"+method, strings.NewReader("{}"))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Origin", "https://attacker.example")
			req.RemoteAddr = remote
			w := httptest.NewRecorder()
			s.handle(w, req)
			if w.Code != http.StatusForbidden {
				t.Fatalf("%s from %s returned %d, want 403", method, remote, w.Code)
			}
		}
	}
	if s.accountSwitchRequired() {
		t.Fatal("cross-origin logout request modified the account gate")
	}
}
