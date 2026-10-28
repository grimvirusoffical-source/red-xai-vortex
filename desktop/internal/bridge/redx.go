package bridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
)

// RedX account gate: every desktop app requires a red-xai.com account,
// checked against the public accounts API over plain HTTPS.
// Owner credentials never exempt a user from verified account sign-in.

const redxAccounts = "https://api.red-xai.com/v1/accounts/"

var redxCli = &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func redxDo(method, path string, hdr map[string]string, body any) (int, map[string]any) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, redxAccounts+path, rd)
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := redxCli.Do(req)
	if err != nil {
		return 0, map[string]any{"message": "RedX accounts unreachable"}
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out)
	if out == nil {
		out = map[string]any{}
	}
	return resp.StatusCode, out
}

func (s *Server) termsFile() string { return filepath.Join(s.rootDirectory(), "terms-accepted") }

func (s *Server) isOwner() bool {
	if s.profileID == "" || s.profileClosed.Load() {
		return false
	}
	k := s.credential("admin-primary")
	if s.baseCredential != nil {
		k = s.baseCredential("admin-primary") // isolate owner checks in tests
	}
	if k == "" {
		return false
	}
	base := os.Getenv("VORTEX_ADMIN_BASE")
	if base == "" {
		base = "http://127.0.0.1:18092"
	}
	req, _ := http.NewRequest("GET", base+"/admin/system", nil)
	req.Header.Set("Authorization", "Bearer "+k)
	resp, err := (&http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == 200
}

func (s *Server) redx(m string, in map[string]any) map[string]any {
	str := func(k string) string { v, _ := in[k].(string); return strings.TrimSpace(v) }
	switch m {
	case "gate.status":
		b, _ := os.ReadFile(s.termsFile())
		terms := strings.TrimSpace(string(b))
		if s.accountSwitchRequired() {
			return s.accountGateResult(terms)
		}
		epoch := s.accountEpoch()
		if linked, email, message := s.quickSignedIn(); linked {
			s.quickAuth.mu.Lock()
			subject := s.quickAuth.account.sub
			expires := s.quickAuth.account.expires
			s.quickAuth.mu.Unlock()
			if err := s.activateAccount(subject, email, "", expires, epoch); err != nil {
				return map[string]any{"ok": false, "message": err.Error()}
			}
			return s.accountGateResult(terms)
		} else if message != "" {
			s.clearAccountWorkspace()
			result := s.accountGateResult(terms)
			result["message"] = message
			return result
		}
		if token := keyring.Get("redx-session"); token != "" {
			status, response := redxDo("GET", "me", map[string]string{"X-RedX-Session": token}, nil)
			if status == 200 {
				if account, ok := verifiedAccountView(response); ok {
					if err := s.activateAccount(accountSubject(account), asString(account["username"]), token, time.Now().Add(5*time.Minute), epoch); err == nil {
						return s.accountGateResult(terms)
					}
				}
			}
			// Do not interpret a cached username, transport outage or admin key
			// as verified identity. Existing local data is kept, not loaded.
			if status == 401 || status == 403 {
				_ = keyring.Set("redx-session", "")
			}
		}
		s.clearAccountWorkspace()
		return s.accountGateResult(terms)
	case "redx.quick.start":
		return s.quickStart()
	case "redx.quick.open":
		return s.quickOpen(str("browser"))
	case "redx.quick.poll":
		epoch := s.accountEpoch()
		out := s.quickPoll()
		if out["signedIn"] == true {
			s.quickAuth.mu.Lock()
			a := s.quickAuth.account
			s.quickAuth.mu.Unlock()
			if err := s.activateAccount(a.sub, a.email, "", a.expires, epoch); err != nil {
				return map[string]any{"ok": false, "error": err.Error()}
			}
			s.accounts.mu.Lock()
			if epoch == s.accounts.epoch {
				_ = s.setAccountSwitchRequired(false)
			} else {
				out = map[string]any{"ok": false, "error": "Sign-in cancelled"}
			}
			s.accounts.mu.Unlock()
		}
		return out
	case "redx.quick.cancel":
		return s.quickCancel()
	case "gate.accept":
		os.WriteFile(s.termsFile(), []byte(str("version")), 0600)
		return map[string]any{"ok": true}
	case "redx.login":
		epoch := s.accountEpoch()
		st, r := redxDo("POST", "login", nil, map[string]any{"login": str("login"), "password": in["password"]})
		return s.redxFinishAt(st, r, epoch)
	case "redx.2fa":
		epoch := s.accountEpoch()
		st, r := redxDo("POST", "login/2fa", map[string]string{"X-RedX-Flow": str("flow")}, map[string]any{"method": str("method"), "code": str("code")})
		return s.redxFinishAt(st, r, epoch)
	case "redx.call":
		st, r := redxDo("POST", "login/call", map[string]string{"X-RedX-Flow": str("flow")}, map[string]any{})
		r["ok"] = st == 200
		return r
	case "redx.logout":
		// Persist the account-switch choice BEFORE revoking credentials. A
		// saved owner/admin key must not silently re-open the workspace.
		if err := s.setAccountSwitchRequired(true); err != nil {
			return map[string]any{"ok": false, "error": "Could not save sign-out state: " + err.Error()}
		}
		s.clearAccountWorkspace()
		s.quickCancel()
		legacy := keyring.Get("redx-session")
		_ = keyring.Set("redx-session", "")
		s.quickLogout()
		if legacy != "" {
			// Remote revocation is best effort; cleared local credentials already
			// prevent the old account from reopening the desktop.
			go redxDo("POST", "logout", map[string]string{"X-RedX-Session": legacy}, map[string]any{})
		}
		return map[string]any{"ok": true}
	case "redx.owner.continue":
		return map[string]any{"ok": false, "error": "Sign in to the owner’s Red-XAI account. A saved admin key does not bypass account authentication."}
	}
	return map[string]any{"ok": false, "error": "unknown method " + m}
}

func (s *Server) redxFinish(st int, r map[string]any) map[string]any {
	return s.redxFinishAt(st, r, s.accountEpoch())
}
func (s *Server) redxFinishAt(status int, response map[string]any, epoch uint64) map[string]any {
	if status == 200 {
		if next, _ := response["next"].(string); next != "" {
			return map[string]any{"ok": true, "next": next, "flow": response["token"], "methods": response["methods"]}
		}
		if token, _ := response["token"].(string); token != "" {
			st, me := redxDo("GET", "me", map[string]string{"X-RedX-Session": token}, nil)
			account, ok := verifiedAccountView(me)
			if st != 200 || !ok {
				return map[string]any{"ok": false, "error": "The account session could not be verified."}
			}
			s.quickLogout()
			s.accounts.mu.Lock()
			if epoch != s.accounts.epoch {
				s.accounts.mu.Unlock()
				return map[string]any{"ok": false, "error": "Sign-in cancelled"}
			}
			err := keyring.Set("redx-session", token)
			s.accounts.mu.Unlock()
			if err != nil {
				return map[string]any{"ok": false, "error": "Could not save the account session."}
			}
			if err = s.activateAccount(accountSubject(account), asString(account["username"]), token, time.Now().Add(5*time.Minute), epoch); err != nil {
				return map[string]any{"ok": false, "error": err.Error()}
			}
			s.accounts.mu.Lock()
			if epoch != s.accounts.epoch {
				s.accounts.mu.Unlock()
				return map[string]any{"ok": false, "error": "Sign-in cancelled"}
			}
			_ = s.setAccountSwitchRequired(false)
			s.accounts.mu.Unlock()
			return map[string]any{"ok": true, "signedIn": true}
		}
	}
	message, _ := response["message"].(string)
	if message == "" {
		message = "Sign-in failed."
	}
	return map[string]any{"ok": false, "error": message}
}
