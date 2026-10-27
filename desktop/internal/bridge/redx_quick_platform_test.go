package bridge

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestQuickApprovalUsesExactOpaqueFragment(t *testing.T) {
	good := "https://red-xai.com/redxai-connectx#request=" + strings.Repeat("a", 43)
	if !checkQuickURL(good) {
		t.Fatal("correct website approval fragment rejected")
	}
	for _, bad := range []string{
		"https://evil.example/redxai-connectx#request=" + strings.Repeat("a", 43),
		"https://red-xai.com/redxai-connectx#wrong=" + strings.Repeat("a", 43),
		"https://red-xai.com/redxai-connectx#request=short",
		"http://red-xai.com/redxai-connectx#request=" + strings.Repeat("a", 43),
		"https://red-xai.com/redxai-connectx#request=" + strings.Repeat("!", 43),
	} {
		if checkQuickURL(bad) {
			t.Errorf("unsafe approval URL accepted: %s", bad)
		}
	}
}
func TestQuickBrowserOpenRejectsInvalidChoiceAndArbitraryURLs(t *testing.T) {
	url := "https://red-xai.com/redxai-connectx#request=" + strings.Repeat("b", 43)
	if _, err := quickBrowserCommand("unknown-browser", url); err == nil {
		t.Fatal("arbitrary browser accepted")
	}
	if _, err := quickBrowserCommand("default", "https://other.example/"); err == nil {
		t.Fatal("arbitrary external URL accepted")
	}
	if _, err := quickBrowserCommand("default", url); err != nil {
		t.Fatalf("default browser blocked: %v", err)
	}
}
func TestVortexNoTrustSessionDoesNotRequirePersistence(t *testing.T) {
	raw := quickFixture()
	raw["remember_device"] = false
	account, err := parseQuickAccount(raw, "user-vortex-123")
	if err != nil {
		t.Fatal(err)
	}
	if account.remember {
		t.Fatal("declined device trust must not persist")
	}
	raw["remember_device"] = true
	account, err = parseQuickAccount(raw, "user-vortex-123")
	if err != nil || !account.remember {
		t.Fatal("trusted session not recognized")
	}
}
func TestQuickLoginBridgeRejectsRemoteAndCrossOriginRequests(t *testing.T) {
	s := &Server{}
	for _, v := range []struct{ name, peer, origin string }{
		{"remote network", "203.0.113.4:3344", "http://127.0.0.1:11774"},
		{"cross origin", "127.0.0.1:3344", "https://evil.example"},
	} {
		t.Run(v.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "http://127.0.0.1:11774/bridge/redx.quick.open", strings.NewReader("{}"))
			req.RemoteAddr = v.peer
			req.Header.Set("Origin", v.origin)
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			s.handle(w, req)
			if w.Code != 403 {
				t.Errorf("HTTP %d should be 403", w.Code)
			}
		})
	}
}
