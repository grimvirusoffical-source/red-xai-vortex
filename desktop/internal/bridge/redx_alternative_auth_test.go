package bridge

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestQuickLoginGrantOpensGateWithoutLegacyPasswordOrMFA(t *testing.T) {
	s := workspaceServer(t)
	if err := os.WriteFile(s.termsFile(), []byte("2026-10-25"), 0600); err != nil {
		t.Fatal(err)
	}
	s.quickAuth.account = quickAccount{
		access:   "rxca_" + strings.Repeat("a", 43),
		refresh:  "rxcr_" + strings.Repeat("b", 43),
		sub:      "signed-in-on-website",
		email:    "quick-approval@test.invalid",
		expires:  time.Now().Add(time.Hour),
		remember: false,
	}
	gate := s.redx("gate.status", nil)
	if gate["ok"] != true || gate["signedIn"] != true ||
		gate["username"] != "quick-approval@test.invalid" ||
		gate["termsAccepted"] != "2026-10-25" {
		t.Fatalf("Quick Login did not unlock the Vortex gate: %#v", gate)
	}
	if gate["owner"] == true {
		t.Fatal("Quick Login must not need a separate owner/password verification")
	}
}

func TestQuickLoginSessionOnlyRefreshIsMemoryOnly(t *testing.T) {
	previous := quickHTTP
	t.Cleanup(func() { quickHTTP = previous })
	refreshCalls := 0
	quickHTTP = &http.Client{Transport: quickTransport(func(req *http.Request) (*http.Response, error) {
		if req.Method != "POST" || req.URL.String() != "https://red-xai.com/redxai-connect/refresh" {
			t.Errorf("unexpected approval refresh: %s", req.URL)
		}
		var body map[string]any
		raw, _ := io.ReadAll(req.Body)
		_ = json.Unmarshal(raw, &body)
		if body["client_id"] != "vortex" ||
			body["refresh_token"] != "rxcr_"+strings.Repeat("b", 43) {
			t.Error("app-scoped in-memory refresh was not used")
		}
		refreshCalls++
		fixture := quickFixture()
		fixture["remember_device"] = false
		payload, _ := json.Marshal(fixture)
		return &http.Response{
			StatusCode: 200,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(string(payload))),
			Request:    req,
		}, nil
	})}
	s := &Server{}
	s.quickAuth.account = quickAccount{
		access:  "rxca_" + strings.Repeat("a", 43),
		refresh: "rxcr_" + strings.Repeat("b", 43),
		sub:     "user-vortex-123", email: "quick-approval@test.invalid",
		expires: time.Now().Add(15 * time.Second), remember: false,
	}
	ready, email, message := s.quickSignedIn()
	if !ready || message != "" || email != "example@test.invalid" || refreshCalls != 1 {
		t.Fatalf("temporary Quick Login lost state: ready=%v email=%q message=%q calls=%d", ready, email, message, refreshCalls)
	}
	if s.quickAuth.account.remember {
		t.Fatal("temporary grant must not be persisted")
	}
}
