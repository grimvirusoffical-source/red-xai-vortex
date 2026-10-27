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
// Owner mode (admin key + SSH tunnel to the admin port) is exempt.

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
	k := keyring.Get("admin-primary")
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
		b, _ := os.ReadFile(s.termsFile())
		res := map[string]any{"ok": true, "termsAccepted": strings.TrimSpace(string(b))}
		// A Vortex-scoped browser grant is a COMPLETE, alternative sign-in.
		// Never require legacy password/MFA or a slow owner-admin check afterward.
		if linked, email, message := s.quickSignedIn(); linked {
			_ = s.setAccountSwitchRequired(false)
			res["signedIn"] = true
			res["username"] = email
			return res
		} else if message != "" {
			res["message"] = message
		}
		ownerAvailable := s.isOwner()
		res["owner"] = ownerAvailable && !s.accountSwitchRequired()
		res["ownerAvailable"] = ownerAvailable
		if tok := keyring.Get("redx-session"); tok != "" {
			st, me := redxDo("GET", "me", map[string]string{"X-RedX-Session": tok}, nil)
			switch {
			case st == 200:
				_ = s.setAccountSwitchRequired(false)
				res["signedIn"] = true
				if a, ok := me["account"].(map[string]any); ok {
					res["username"] = a["username"]
				}
			case st == 0 || st >= 500:
				res["signedIn"] = true // offline grace with a saved session
				res["message"] = "RedX accounts unreachable; using your saved sign-in."
			default:
				keyring.Set("redx-session", "")
			}
		}
		return res
	case "redx.quick.start":
		return s.quickStart()
	case "redx.quick.open":
		return s.quickOpen(str("browser"))
	case "redx.quick.poll":
		return s.quickPoll()
	case "redx.quick.cancel":
		return s.quickCancel()
	case "gate.accept":
		os.WriteFile(s.termsFile(), []byte(str("version")), 0600)
		return map[string]any{"ok": true}
	case "redx.login":
		st, r := redxDo("POST", "login", nil, map[string]any{"login": str("login"), "password": in["password"]})
		return s.redxFinish(st, r)
	case "redx.2fa":
		st, r := redxDo("POST", "login/2fa", map[string]string{"X-RedX-Flow": str("flow")}, map[string]any{"method": str("method"), "code": str("code")})
		return s.redxFinish(st, r)
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
		if !s.isOwner() { return map[string]any{"ok": false, "error": "Owner mode is not available"} }
		if err := s.setAccountSwitchRequired(false); err != nil {
			return map[string]any{"ok": false, "error": "Could not restore owner mode"}
		}
		return map[string]any{"ok": true}
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
			keyring.Set("redx-session", tok)
			_ = s.setAccountSwitchRequired(false)
			return map[string]any{"ok": true, "signedIn": true}
		}
	}
	msg, _ := r["message"].(string)
	if msg == "" {
		msg = "Sign-in failed."
	}
	return map[string]any{"ok": false, "error": msg}
}
