package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func canonicalFixture() map[string]any {
	return map[string]any{"account": map[string]any{"id": "Account-A", "username": "alice", "roles": []any{"user"}},
		"expiresMs": json.Number("4102444800000"), "amr": []any{"pwd"}}
}

func TestOwnerRequiresExactCanonicalIDRoleCompletedMFAAndExpiry(t *testing.T) {
	previous := cpcOwnerIDs
	cpcOwnerIDs = map[string]bool{"Account-A": true}
	t.Cleanup(func() { cpcOwnerIDs = previous })
	for _, test := range []struct {
		name   string
		change func(map[string]any)
		valid  bool
		owner  bool
	}{
		{"normal password", func(map[string]any) {}, true, false},
		{"owner role without MFA", func(m map[string]any) { m["account"].(map[string]any)["roles"] = []any{"owner"} }, true, false},
		{"MFA without owner role", func(m map[string]any) { m["amr"] = []any{"pwd", "totp"} }, true, false},
		{"all owner proofs", func(m map[string]any) {
			m["account"].(map[string]any)["roles"] = []any{"owner"}
			m["amr"] = []any{"pwd", "totp"}
		}, true, true},
		{"different ID same owner username", func(m map[string]any) {
			a := m["account"].(map[string]any)
			a["id"] = "account-a"
			a["roles"] = []any{"owner"}
			a["owner"] = true
			m["amr"] = []any{"totp"}
		}, true, false},
		{"email and legacy username owner hints", func(m map[string]any) {
			a := m["account"].(map[string]any)
			a["id"] = "Account-B"
			a["username"] = "jf"
			a["email"] = "owner@example.test"
			a["owner"] = true
		}, true, false},
		{"pending MFA", func(m map[string]any) { m["pending"] = []any{"2fa_setup"} }, false, false},
		{"account pending", func(m map[string]any) { m["account"].(map[string]any)["pending"] = []any{"tos"} }, false, false},
		{"expired", func(m map[string]any) { m["expiresMs"] = json.Number("1") }, false, false},
		{"missing expiry", func(m map[string]any) { delete(m, "expiresMs") }, false, false},
		{"noninteger expiry", func(m map[string]any) { m["expiresMs"] = json.Number("4102444800000.5") }, false, false},
		{"missing AMR", func(m map[string]any) { delete(m, "amr") }, false, false},
		{"unverified", func(m map[string]any) { m["account"].(map[string]any)["emailVerified"] = false }, false, false},
		{"banned", func(m map[string]any) { m["account"].(map[string]any)["status"] = "banned" }, false, false},
		{"malformed subject", func(m map[string]any) { m["account"].(map[string]any)["id"] = "Account A" }, false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			m := canonicalFixture()
			test.change(m)
			identity, valid := canonicalAccount(m, time.Now())
			if valid != test.valid || identity.Owner != test.owner {
				t.Fatalf("valid=%v owner=%v, expected valid=%v owner=%v", valid, identity.Owner, test.valid, test.owner)
			}
		})
	}
	if _, valid := canonicalAccount(map[string]any{"id": "Account-A", "owner": true, "twoFactorState": "active", "pending": []any{}}, time.Now()); valid {
		t.Fatal("separate modern flat Me response invented missing session proof")
	}
}

func TestOwnerIDConfigurationIsCaseSensitiveAndHasNoUsernameFallback(t *testing.T) {
	for _, value := range []string{"Account-A,", "Account A", ",Account-A"} {
		if _, err := parseOwnerAccountIDs(value); err == nil {
			t.Fatal("invalid private owner IDs accepted")
		}
	}
	ids, err := parseOwnerAccountIDs("Account-A, Account-B")
	if err != nil || !ids["Account-A"] || ids["account-a"] {
		t.Fatal("owner IDs were inferred or case folded")
	}
	t.Setenv("CPC_OWNERS", "jf,maindirectory,alice")
	ids, err = parseOwnerAccountIDs("")
	if err != nil || len(ids) != 0 {
		t.Fatal("legacy usernames granted ownership")
	}
}

func TestIncompleteAuthorityTokensCannotCompleteCloudPCSignIn(t *testing.T) {
	if completedToken(map[string]any{"token": "synthetic-completed-token"}) == "" {
		t.Fatal("known completed token response rejected")
	}
	for _, response := range []map[string]any{
		{"token": "synthetic-flow-token", "next": "2fa"},
		{"token": "synthetic-flow-token", "next": "2fa_setup"},
		{"token": "synthetic-flow-token", "next": "unknown-step"},
		{"token": "synthetic-flow-token", "pending": []any{"tos"}},
		{"token": "synthetic-flow-token", "challenge": true},
		{"token": "synthetic-flow-token", "error": "tries"},
	} {
		if completedToken(response) != "" {
			t.Fatal("incomplete token response treated as a completed session")
		}
	}
}

func TestCanonicalIDsOwnGrantsEvenWhenUsernamesCollideOrChange(t *testing.T) {
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	if err := saveACL(aclFile{Schema: aclSchema, Approved: []string{"Account-A"}}); err != nil {
		t.Fatal(err)
	}
	identity := func(id, username string) *sess {
		return &sess{account: accountIdentity{ID: id, Username: username, ExpiresMs: time.Now().Add(time.Hour).UnixMilli()}}
	}
	if !isApproved(identity("Account-A", "renamed")) || isApproved(identity("account-a", "alice")) || isApproved(identity("Account-B", "alice")) {
		t.Fatal("mutable username or ID case selected another account's grant")
	}
	legacy := []byte(`{"approved":["alice"],"pending":{"bob":"fixture-time"}}`)
	if err := os.WriteFile(aclPath(), legacy, 0600); err != nil {
		t.Fatal(err)
	}
	if isApproved(identity("alice", "alice")) {
		t.Fatal("legacy username ACL was reinterpreted as IDs")
	}
	called := false
	if err := mutateACL(func(a *aclFile) { called = true }); err == nil || called {
		t.Fatal("legacy ACL was automatically migrated")
	}
	actual, _ := os.ReadFile(aclPath())
	if !bytes.Equal(actual, legacy) {
		t.Fatal("legacy grant evidence overwritten")
	}
}

func TestPrivilegedGrantMutationsUseIDsAndPersistAuditTogether(t *testing.T) {
	current := cloudOwnerFixture(t)
	request := cloudRequest(http.MethodPost, "/approve")
	request.Header.Set("Origin", "https://cloud.example")
	request.Form = map[string][]string{"account_id": {"Account-B"}, "user": {"alice"}}
	w := httptest.NewRecorder()
	cloud(w, request)
	if w.Code != http.StatusOK {
		t.Fatalf("canonical owner approval failed: %d %s", w.Code, w.Body.String())
	}
	a, err := loadACL()
	if err != nil || len(a.Approved) != 1 || a.Approved[0] != "Account-B" || len(a.Audit) != 1 || a.Audit[0].Actor != current.account.ID || a.Audit[0].Target != "Account-B" || a.Audit[0].Event != "approve" {
		t.Fatalf("ID-bound grant and audit not persisted together: %+v %v", a, err)
	}
	request = cloudRequest(http.MethodPost, "/deny")
	request.Header.Set("Origin", "https://cloud.example")
	request.Form = map[string][]string{"account_id": {"Account-B"}}
	w = httptest.NewRecorder()
	cloud(w, request)
	a, err = loadACL()
	if w.Code != http.StatusOK || err != nil || len(a.Approved) != 0 || len(a.Audit) != 2 || a.Audit[1].Event != "deny" {
		t.Fatal("canonical revoke/audit failed")
	}
}

func TestOwnerRoleOrMFARevocationDropsLocalSession(t *testing.T) {
	for _, revoke := range []string{"role", "mfa"} {
		t.Run(revoke, func(t *testing.T) {
			current := cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
				m := canonicalFixture()
				a := m["account"].(map[string]any)
				a["id"] = "account-a"
				a["username"] = "alice"
				a["roles"] = []any{"owner"}
				m["amr"] = []any{"pwd", "totp"}
				if revoke == "role" {
					a["roles"] = []any{"user"}
				} else {
					m["amr"] = []any{"pwd"}
				}
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(m)
			})
			cpcOwnerIDs["account-a"] = true
			current.account.Owner = true
			if _, accepted := getSess(cloudRequest(http.MethodGet, "/")); accepted != nil {
				t.Fatal("revoked owner proof retained local session")
			}
		})
	}
}

func TestDesktopStorageIDStillHashesOriginalCanonicalID(t *testing.T) {
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		m := canonicalFixture()
		m["account"].(map[string]any)["id"] = "Mixed-Case-ID"
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(m)
	})
	r := httptest.NewRequest(http.MethodPost, "https://cloud.example/vortex/signin", nil)
	w := httptest.NewRecorder()
	finish(w, r, "synthetic-session", "/vortex/")
	if w.Code != http.StatusSeeOther {
		t.Fatal("canonical completion failed")
	}
	var token string
	for _, cookie := range w.Result().Cookies() {
		if cookie.Name == "cpc" {
			token = cookie.Value
			if !cookie.Secure {
				t.Fatal("native TLS cookie lost Secure")
			}
		}
	}
	mu.Lock()
	session := sessions[token]
	mu.Unlock()
	expected := sum256([]byte("cloudpc-redx:" + "Mixed-Case-ID"))
	if session == nil || session.id != hex.EncodeToString(expected[:8]) || session.account.ID != "Mixed-Case-ID" || strings.Contains(session.id, "alice") {
		t.Fatal("existing canonical desktop storage hash changed")
	}
}
