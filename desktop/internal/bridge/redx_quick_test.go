package bridge

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type quickTransport func(*http.Request) (*http.Response, error)

func (t quickTransport) RoundTrip(req *http.Request) (*http.Response, error) { return t(req) }
func quickFixture() map[string]any {
	return map[string]any{
		"protocol": "redx-site-session-v1", "issuer": "https://red-xai.com",
		"client_id": "vortex", "scope": "vortex.app", "token_type": "Bearer",
		"access_token":  "rxca_" + strings.Repeat("a", 43),
		"refresh_token": "rxcr_" + strings.Repeat("b", 43),
		"expires_in":    float64(3600),
		"user":          map[string]any{"sub": "user-vortex-123", "email": "example@test.invalid", "email_verified": true},
	}
}
func TestQuickAccountRequiresVortexScopeAndIdentity(t *testing.T) {
	a, err := parseQuickAccount(quickFixture(), "user-vortex-123")
	if err != nil || a.sub != "user-vortex-123" || time.Until(a.expires) < 3500*time.Second {
		t.Fatalf("valid Vortex session rejected: %v", err)
	}
	cases := map[string]func(map[string]any){
		"other app":         func(v map[string]any) { v["client_id"] = "gendragoon" },
		"storage scope":     func(v map[string]any) { v["scope"] = "gendragoon.receiver" },
		"bad issuer":        func(v map[string]any) { v["issuer"] = "https://elsewhere.invalid" },
		"non-bearer":        func(v map[string]any) { v["token_type"] = "Basic" },
		"short token":       func(v map[string]any) { v["access_token"] = "rxca_short" },
		"bad token charset": func(v map[string]any) { v["access_token"] = "rxca_" + strings.Repeat("!", 43) },
		"unverified":        func(v map[string]any) { v["user"].(map[string]any)["email_verified"] = false },
		"expires too late":  func(v map[string]any) { v["expires_in"] = float64(7200) },
		"expires zero":      func(v map[string]any) { v["expires_in"] = float64(0) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			v := quickFixture()
			mutate(v)
			if _, err := parseQuickAccount(v, "user-vortex-123"); err == nil {
				t.Error("accepted unsafe session")
			}
		})
	}
	if _, err := parseQuickAccount(quickFixture(), "other-user"); err == nil {
		t.Error("cross-account refresh accepted")
	}
}
func TestQuickApprovalURLIsOriginBound(t *testing.T) {
	yes := []string{"https://red-xai.com/redxai-connect", "https://red-xai.com/redxai-connect/?code=ABCD1234"}
	no := []string{"http://red-xai.com/redxai-connect", "https://red-xai.com.evil.invalid/redxai-connect", "https://evil.invalid/redxai-connect", "https://user@red-xai.com/redxai-connect", "https://red-xai.com/redxai-connect#fragment", "https://red-xai.com/vortex/"}
	for _, u := range yes {
		if !checkQuickURL(u) {
			t.Errorf("safe approval URL rejected: %s", u)
		}
	}
	for _, u := range no {
		if checkQuickURL(u) {
			t.Errorf("unsafe approval URL accepted: %s", u)
		}
	}
}
func TestQuickStartReusesSinglePendingApproval(t *testing.T) {
	old := quickHTTP
	defer func() { quickHTTP = old }()
	calls := 0
	quickHTTP = &http.Client{Transport: quickTransport(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.URL.String() != "https://red-xai.com/redxai-connect/start" || req.Method != "POST" {
			t.Errorf("unexpected request: %s", req.URL)
		}
		raw, _ := io.ReadAll(req.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		if body["client_id"] != "vortex" || body["code_challenge_method"] != "S256" ||
			len(asString(body["code_challenge"])) != 43 {
			t.Error("missing separate PKCE Vortex client")
		}
		payload, _ := json.Marshal(map[string]any{"device_code": strings.Repeat("a", 43), "user_code": "TEST1234", "verification_uri": "https://red-xai.com/redxai-connect", "expires_in": 300, "interval": 3})
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: io.NopCloser(strings.NewReader(string(payload))), Request: req}, nil
	})}
	s := &Server{}
	start := s.quickStart()
	if start["ok"] != true || start["code"] != "TEST1234" {
		t.Fatalf("quick start failed: %v", start)
	}
	again := s.quickStart()
	if again["code"] != "TEST1234" || calls != 1 {
		t.Fatalf("approval duplicated: calls=%d reply=%v", calls, again)
	}
	if s.quickCancel()["ok"] != true {
		t.Fatal("cancel failed")
	}
	if s.quickPoll()["ok"] != false {
		t.Fatal("cancelled approval could still poll")
	}
}
func TestQuickPKCEVerifierIsRandomAndExpectedLength(t *testing.T) {
	a, err := randomVerifier()
	if err != nil {
		t.Fatal(err)
	}
	b, err := randomVerifier()
	if err != nil {
		t.Fatal(err)
	}
	if a == b || len(a) != 43 || len(b) != 43 {
		t.Fatal("verifier is predictable or malformed")
	}
	hash := sha256.Sum256([]byte(a))
	if len(base64.RawURLEncoding.EncodeToString(hash[:])) != 43 {
		t.Fatal("invalid S256 challenge")
	}
}
