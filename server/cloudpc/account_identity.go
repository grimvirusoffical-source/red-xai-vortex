package main

import (
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode"
)

type accountIdentity struct {
	ID, Username string
	Owner        bool
	ExpiresMs    int64
}

// Exact, case-sensitive canonical IDs, configured privately after independent
// verification. Usernames/emails and the former CPC_OWNERS setting grant nothing.
var cpcOwnerIDs = map[string]bool{}

func validAccountID(value string) bool {
	return value != "" && len(value) <= 256 && !strings.ContainsFunc(value, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsControl(r)
	})
}

func parseOwnerAccountIDs(value string) (map[string]bool, error) {
	ids := map[string]bool{}
	if strings.TrimSpace(value) == "" {
		return ids, nil
	}
	if len(value) > 16384 {
		return nil, errors.New("invalid CPC_OWNER_ACCOUNT_IDS")
	}
	for _, part := range strings.Split(value, ",") {
		id := strings.TrimSpace(part)
		if !validAccountID(id) {
			return nil, errors.New("invalid CPC_OWNER_ACCOUNT_IDS")
		}
		ids[id] = true
	}
	return ids, nil
}

func stringClaims(value any) ([]string, bool) {
	values, ok := value.([]any)
	if !ok || len(values) > 40 {
		return nil, false
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		text, ok := value.(string)
		if !ok || text == "" || len(text) > 64 || strings.ContainsFunc(text, unicode.IsControl) {
			return nil, false
		}
		out = append(out, text)
	}
	return out, true
}

func hasClaim(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func noPending(object map[string]any) bool {
	value, exists := object["pending"]
	if !exists {
		return true
	}
	values, ok := value.([]any)
	return ok && len(values) == 0
}

func completedToken(response map[string]any) string {
	if next, exists := response["next"]; exists && next != "" {
		return ""
	}
	if _, exists := response["error"]; exists {
		return ""
	}
	if _, exists := response["challenge"]; exists {
		return ""
	}
	if !noPending(response) {
		return ""
	}
	token := str(response, "token")
	if token == "" || len(token) > 8192 || strings.ContainsFunc(token, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) {
		return ""
	}
	return token
}

func canonicalAccount(response map[string]any, now time.Time) (accountIdentity, bool) {
	account, ok := response["account"].(map[string]any)
	if !ok || !noPending(response) || !noPending(account) {
		return accountIdentity{}, false
	}
	id, username := str(account, "id"), str(account, "username")
	if !validAccountID(id) || len(username) > 256 || strings.ContainsFunc(username, unicode.IsControl) {
		return accountIdentity{}, false
	}
	for _, object := range []map[string]any{response, account} {
		for _, field := range []string{"active", "emailVerified", "email_verified"} {
			if value, exists := object[field]; exists && value != true {
				return accountIdentity{}, false
			}
		}
		for _, field := range []string{"disabled", "banned", "deleted"} {
			if value, exists := object[field]; exists && value != false {
				return accountIdentity{}, false
			}
		}
		for _, field := range []string{"status", "state"} {
			if value, exists := object[field]; exists && value != "active" && value != "activated" {
				return accountIdentity{}, false
			}
		}
	}
	expires, ok := response["expiresMs"].(json.Number)
	if !ok {
		return accountIdentity{}, false
	}
	expiresMs, err := expires.Int64()
	if err != nil || expiresMs <= now.UnixMilli() || expiresMs > 9007199254740991 {
		return accountIdentity{}, false
	}
	amr, ok := stringClaims(response["amr"])
	if !ok || len(amr) == 0 {
		return accountIdentity{}, false
	}
	roles, ok := stringClaims(account["roles"])
	if !ok {
		return accountIdentity{}, false
	}
	mfa := false
	for _, method := range []string{"otp", "totp", "sms", "call", "mfa", "webauthn"} {
		mfa = mfa || hasClaim(amr, method)
	}
	return accountIdentity{ID: id, Username: username, ExpiresMs: expiresMs,
		Owner: cpcOwnerIDs[id] && hasClaim(roles, "owner") && mfa}, true
}
