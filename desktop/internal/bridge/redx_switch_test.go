package bridge

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDesktopOwnerShortcutNeverBypassesAccountSignIn(t *testing.T) {
	s := workspaceServer(t)
	s.baseCredential = func(string) string { return "fixture-admin-key" }
	if s.isOwner() {
		t.Fatal("a root/global credential unlocked owner mode")
	}
	if err := s.setAccountSwitchRequired(true); err != nil {
		t.Fatal(err)
	}
	g := s.redx("gate.status", nil)
	if g["owner"] != false || g["ownerAvailable"] != false || g["signedIn"] == true {
		t.Fatalf("owner shortcut exposed before login: %v", g)
	}
	if s.redx("redx.owner.continue", nil)["ok"] == true {
		t.Fatal("owner shortcut bypassed account sign-in")
	}
	if !s.accountSwitchRequired() {
		t.Fatal("owner shortcut removed signed-out marker")
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
