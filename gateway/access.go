package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Access controls: global IP allow/deny, per-key IP rules, roles, expiry,
// enable/disable, download permission, and a bounded owner audit log.

type ACL struct {
	Allow []string `json:"allow"` // empty = any
	Deny  []string `json:"deny"`
}

var (
	acl   ACL
	aclMu sync.Mutex
)

func loadACL() {
	if b, err := os.ReadFile(filepath.Join(dir, "acl.json")); err == nil {
		json.Unmarshal(b, &acl)
	}
}

func ipMatch(ip string, rules []string) bool {
	pip := net.ParseIP(ip)
	for _, r := range rules {
		r = strings.TrimSpace(r)
		if r == "" {
			continue
		}
		if strings.Contains(r, "/") {
			if _, n, err := net.ParseCIDR(r); err == nil && pip != nil && n.Contains(pip) {
				return true
			}
		} else if r == ip {
			return true
		}
	}
	return false
}

func ipAllowedGlobal(ip string) bool {
	aclMu.Lock()
	a := acl
	aclMu.Unlock()
	if ipMatch(ip, a.Deny) {
		return false
	}
	return len(a.Allow) == 0 || ipMatch(ip, a.Allow)
}

func keyIPAllowed(k *Key, ip string) bool {
	if ipMatch(ip, k.IPDeny) {
		return false
	}
	return len(k.IPAllow) == 0 || ipMatch(ip, k.IPAllow)
}

func roleOf(k *Key) string {
	if k.Admin {
		if k.Role == "owner" {
			return "owner"
		}
		return "admin"
	}
	return "user"
}

func strList(v any) ([]string, bool) {
	a, ok := v.([]any)
	if !ok {
		return nil, false
	}
	var out []string
	for _, x := range a {
		if s, ok := x.(string); ok && strings.TrimSpace(s) != "" {
			out = append(out, strings.TrimSpace(s))
		}
	}
	return out, true
}

// applyKeyPatch sets access fields present in m. Caller holds no lock for new keys; uses mu for existing.
func applyKeyPatch(k *Key, m map[string]any) {
	if v, ok := m["models"]; ok {
		if l, ok := strList(v); ok {
			k.Models = l
		}
	}
	if v, ok := m["rpm"].(float64); ok && v >= 1 && v <= 10000 {
		k.RPM = int(v)
	}
	if v, ok := m["expires"].(float64); ok && v >= 0 {
		k.Expires = int64(v)
	}
	if v, ok := m["expires_days"].(float64); ok {
		if v <= 0 {
			k.Expires = 0
		} else {
			k.Expires = time.Now().Add(time.Duration(v*24) * time.Hour).Unix()
		}
	}
	if v, ok := m["disabled"].(bool); ok {
		k.Disabled = v
	}
	if v, ok := m["can_download"].(bool); ok {
		k.CanDownload = v
	}
	if v, ok := m["role"].(string); ok {
		switch v {
		case "admin":
			k.Admin, k.Role = true, "admin"
		case "user":
			k.Admin, k.Role = false, "user"
		}
	}
	if l, ok := strList(m["ip_allow"]); ok {
		k.IPAllow = l
	}
	if l, ok := strList(m["ip_deny"]); ok {
		k.IPDeny = l
	}
}

// accessAdmin handles /admin/acl, /admin/audit and PATCH /admin/keys/{id}.
func accessAdmin(w http.ResponseWriter, r *http.Request, p string, caller *Key) bool {
	switch {
	case strings.HasPrefix(p, "/admin/audit"):
		return handleAuditAdmin(w, r, p, caller)
	case p == "/admin/acl" && r.Method == "GET":
		aclMu.Lock()
		defer aclMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(acl)
		return true
	case p == "/admin/acl" && r.Method == "POST":
		if !requireOwner(w, r) {
			return true
		}
		var in map[string]any
		json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in)
		aclMu.Lock()
		if l, ok := strList(in["allow"]); ok {
			acl.Allow = l
		}
		if l, ok := strList(in["deny"]); ok {
			acl.Deny = l
		}
		// never lock ourselves out of the loopback tunnel
		if len(acl.Allow) > 0 && !ipMatch("127.0.0.1", acl.Allow) {
			acl.Allow = append(acl.Allow, "127.0.0.1")
		}
		writeJSON("acl.json", acl)
		out := acl
		aclMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(out)
		return true
	case strings.HasPrefix(p, "/admin/keys/") && r.Method == "PATCH":
		if !requireOwner(w, r) {
			return true
		}
		id := strings.TrimPrefix(p, "/admin/keys/")
		var in map[string]any
		json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in)
		mu.Lock()
		var hit *Key
		for _, x := range keys {
			if x.ID == id && x.ID != caller.ID && !strings.HasPrefix(x.ID, "admin_") {
				hit = x
			}
		}
		if hit != nil {
			applyKeyPatch(hit, in)
			saveKeys()
		}
		mu.Unlock()
		if hit == nil {
			errJSON(w, 404, "no such key (or not editable)")
			return true
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
		return true
	}
	return false
}
