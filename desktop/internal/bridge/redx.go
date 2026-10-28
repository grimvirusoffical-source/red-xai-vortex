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
// Owner credentials never replace a verified account or bypass profile isolation.

const redxAccounts = "https://api.red-xai.com/v1/accounts/"

var redxCli = &http.Client{Timeout: 15 * time.Second}

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

func (s *Server) termsFile() string { return filepath.Join(s.St.Dir, "terms-accepted") }

func (s *Server) isOwner() bool {
	if s.accountRoot == nil || !s.profileLive() {
		return false
	}
	k := s.secretGet("admin-primary")
	if k == "" {
		return false
	}
	base := os.Getenv("VORTEX_ADMIN_BASE")
	if base == "" {
		base = "http://127.0.0.1:18092"
	}
	req, _ := http.NewRequest("GET", base+"/admin/system", nil)
	req.Header.Set("Authorization", "Bearer "+k)
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
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
		s.accountVerifyMu.Lock()
		defer s.accountVerifyMu.Unlock()
		epoch := s.accountEpoch()
		b, _ := os.ReadFile(s.termsFile())
		res := map[string]any{"ok": true, "termsAccepted": strings.TrimSpace(string(b)), "owner": false, "ownerAvailable": false, "signedIn": false}
		if s.accountSwitchRequired() {
			return res
		}
		if linked, email, message := s.quickSignedIn(); linked {
			s.quickAuth.mu.Lock()
			sub, expires := s.quickAuth.account.sub, s.quickAuth.account.expires
			s.quickAuth.mu.Unlock()
			profile, err := s.activateVerifiedAccount(sub, "", expires, epoch)
			if err != nil {
				res["message"] = err.Error()
				return res
			}
			res["signedIn"] = true
			res["username"] = email
			res["profile"] = profile.profileToken
			res["accountID"] = profile.profileID
			res["owner"] = profile.isOwner()
			return res
		} else if message != "" {
			res["message"] = message
		}
		if tok := keyring.Get("redx-session"); tok != "" {
			status, me := redxDo("GET", "me", map[string]string{"X-RedX-Session": tok}, nil)
			if status == 200 {
				a, _ := me["account"].(map[string]any)
				sub := asString(a["id"])
				if sub == "" {
					sub = asString(a["sub"])
				}
				if sub == "" {
					sub = asString(a["accountId"])
				}
				profile, err := s.activateVerifiedAccount(sub, tok, time.Now().Add(5*time.Minute), epoch)
				if err == nil {
					res["signedIn"] = true
					res["username"] = a["username"]
					res["profile"] = profile.profileToken
					res["accountID"] = profile.profileID
					res["owner"] = profile.isOwner()
					return res
				}
				res["message"] = err.Error()
			} else if status == 401 || status == 403 {
				_ = keyring.Set("redx-session", "")
			}
		}
		s.lockAccount()
		return res
	case "redx.quick.start":
		return s.quickStart()
	case "redx.quick.open":
		return s.quickOpen(str("browser"))
	case "redx.quick.poll":
		out := s.quickPoll()
		if out["signedIn"] == true {
			_ = s.setAccountSwitchRequired(false)
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
		if s.accountEpoch() != epoch {
			return map[string]any{"ok": false, "error": "Sign-in cancelled by account switch"}
		}
		return s.redxFinish(st, r)
	case "redx.2fa":
		epoch := s.accountEpoch()
		st, r := redxDo("POST", "login/2fa", map[string]string{"X-RedX-Flow": str("flow")}, map[string]any{"method": str("method"), "code": str("code")})
		if s.accountEpoch() != epoch {
			return map[string]any{"ok": false, "error": "Sign-in cancelled by account switch"}
		}
		return s.redxFinish(st, r)
	case "redx.call":
		st, r := redxDo("POST", "login/call", map[string]string{"X-RedX-Flow": str("flow")}, map[string]any{})
		r["ok"] = st == 200
		return r
	case "redx.logout":
		s.lockAccount() // stop old-account tools before any network revocation
		// Persist the account-switch choice BEFORE revoking credentials. A
		// saved owner/admin key must not silently re-open the workspace.
		if err := s.setAccountSwitchRequired(true); err != nil {
			return map[string]any{"ok": false, "error": "Could not save sign-out state: " + err.Error()}
		}
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
		return map[string]any{"ok": false, "error": "Sign in to your Red-XAI account. Owner credentials cannot bypass account authentication."}

	}
	return map[string]any{"ok": false, "error": "unknown method " + m}
}

func (s *Server) redxFinish(st int, r map[string]any) map[string]any {
	if st == 200 {
		if n, _ := r["next"].(string); n != "" {
			return map[string]any{"ok": true, "next": n, "flow": r["token"], "methods": r["methods"]}
		}
		if tok, _ := r["token"].(string); tok != "" {
			s.quickLogout()
			if err := keyring.Set("redx-session", tok); err != nil {
				return map[string]any{"ok": false, "error": "Could not store account session"}
			}
			_ = s.setAccountSwitchRequired(false)
			return s.redx("gate.status", nil)
		}
	}
	msg, _ := r["message"].(string)
	if msg == "" {
		msg = "Sign-in failed."
	}
	return map[string]any{"ok": false, "error": msg}
}
