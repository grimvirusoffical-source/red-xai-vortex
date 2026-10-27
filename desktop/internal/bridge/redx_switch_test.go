package bridge

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
)

func TestDesktopLogoutPersistsAccountSwitchAndKeepsOptionalOwnerMode(t *testing.T) {
	s := workspaceServer(t)
	oldAdmin := keyring.Get("admin-primary")
	oldLegacy := keyring.Get("redx-session")
	t.Cleanup(func() {
		_ = keyring.Set("admin-primary", oldAdmin)
		_ = keyring.Set("redx-session", oldLegacy)
	})
	_ = keyring.Set("admin-primary", "test-only-owner-credential")
	_ = keyring.Set("redx-session", "")
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/admin/system" || r.Header.Get("Authorization") != "Bearer test-only-owner-credential" {
			http.Error(w, "invalid test credential", http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer admin.Close()
	t.Setenv("VORTEX_ADMIN_BASE", admin.URL)
	before := s.redx("gate.status", nil)
	if before["owner"] != true { t.Fatalf("owner fallback should work before logout: %v", before) }
	out := s.redx("redx.logout", nil)
	if out["ok"] != true || !s.accountSwitchRequired() {
		t.Fatalf("logout did not persist account switch: %v", out)
	}
	restarted := &Server{St: s.St}
	g := restarted.redx("gate.status", nil)
	if g["owner"] != false || g["ownerAvailable"] != true || g["signedIn"] == true {
		t.Fatalf("owner mode silently bypassed explicit logout: %v", g)
	}
	mode := restarted.redx("redx.owner.continue", nil)
	if mode["ok"] != true || restarted.accountSwitchRequired() {
		t.Fatalf("explicit owner mode was not restored: %v", mode)
	}
	if restarted.redx("gate.status", nil)["owner"] != true {
		t.Fatal("owner mode disappeared instead of remaining user-selectable")
	}
	if _, err := os.Stat(s.accountSwitchPath()); !os.IsNotExist(err) {
		t.Fatal("persisted account switch marker was not cleared after owner selection")
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
