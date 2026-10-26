package bridge

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
)

// Red-XAI browser approval is the same PKCE-backed flow used by GenDragoon,
// but Vortex must have its OWN client ID and scope. Never accept a storage token.
const (
	vortexAuthOrigin = "https://red-xai.com"
	vortexClientID   = "vortex"
	vortexScope      = "vortex.app"
	quickRefreshKey  = "redx-vortex-refresh"
	quickSubjectKey  = "redx-vortex-subject"
)

var (
	quickSecret = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	quickCode   = regexp.MustCompile(`^[A-Za-z0-9]{8}$`)
	quickHTTP   = &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
)

type quickAccount struct {
	access, refresh, sub, email string
	expires                     time.Time
}
type quickApproval struct {
	code, device, verifier, link string
	deadline, nextPoll           time.Time
	delay                        time.Duration
}
type vortexQuickAuth struct {
	mu       sync.Mutex
	epoch    uint64
	approval quickApproval
	account  quickAccount
	polling  bool
}

func quickRequest(path string, body map[string]any) (int, map[string]any, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return 0, nil, err
	}
	req, err := http.NewRequest("POST", vortexAuthOrigin+"/redxai-connect/"+path, bytes.NewReader(b))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := quickHTTP.Do(req)
	if err != nil {
		return 0, nil, errors.New("Red-XAI approval service is temporarily unreachable")
	}
	defer resp.Body.Close()
	if resp.Request.URL.String() != req.URL.String() || resp.StatusCode/100 == 3 {
		return 0, nil, errors.New("Red-XAI approval unexpectedly redirected")
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 128*1024+1))
	if err != nil || len(raw) > 128*1024 {
		return 0, nil, errors.New("Red-XAI approval returned an oversized response")
	}
	var result map[string]any
	if len(raw) != 0 && json.Unmarshal(raw, &result) != nil {
		return resp.StatusCode, nil, errors.New("Red-XAI approval did not return JSON")
	}
	if result == nil {
		result = map[string]any{}
	}
	return resp.StatusCode, result, nil
}

func checkQuickURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "red-xai.com" || u.User != nil || u.Fragment != "" || u.Opaque != "" {
		return false
	}
	switch u.Path {
	case "/redxai-connect", "/redxai-connect/", "/redxai-connectx":
		return true
	}
	return false
}
func parseQuickAccount(data map[string]any, expected string) (quickAccount, error) {
	var a quickAccount
	if data["protocol"] != "redx-site-session-v1" || data["issuer"] != vortexAuthOrigin ||
		data["client_id"] != vortexClientID || data["scope"] != vortexScope ||
		!strings.EqualFold(asString(data["token_type"]), "bearer") {
		return a, errors.New("Red-XAI returned a token for another application")
	}
	ac, rf := asString(data["access_token"]), asString(data["refresh_token"])
	if len(ac) != 48 || len(rf) != 48 || !strings.HasPrefix(ac, "rxca_") || !strings.HasPrefix(rf, "rxcr_") ||
		!quickSecret.MatchString(ac[5:]) || !quickSecret.MatchString(rf[5:]) {
		return a, errors.New("Red-XAI returned invalid account credentials")
	}
	ttl, ok := data["expires_in"].(float64)
	if !ok || ttl < 1 || ttl > 3600 || ttl != float64(int64(ttl)) {
		return a, errors.New("Red-XAI returned an invalid token lifetime")
	}
	user, ok := data["user"].(map[string]any)
	if !ok || user["email_verified"] != true {
		return a, errors.New("Verify your Red-XAI email before connecting Vortex")
	}
	sub := asString(user["sub"])
	if sub == "" || len(sub) > 256 || (expected != "" && sub != expected) {
		return a, errors.New("The approved Red-XAI account changed")
	}
	return quickAccount{access: ac, refresh: rf, sub: sub, email: asString(user["email"]), expires: time.Now().Add(time.Duration(ttl) * time.Second)}, nil
}
func asString(value any) string { v, _ := value.(string); return v }
func randomVerifier() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func (s *Server) quickStart() map[string]any {
	q := &s.quickAuth
	q.mu.Lock()
	if a := q.approval; a.device != "" && time.Now().Before(a.deadline) {
		q.mu.Unlock()
		return map[string]any{"ok": true, "code": a.code, "url": a.link, "interval": int(a.delay.Seconds())}
	}
	gen := q.epoch
	q.mu.Unlock()
	verifier, err := randomVerifier()
	if err != nil {
		return map[string]any{"ok": false, "error": "Secure random generation failed"}
	}
	hash := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(hash[:])
	status, job, err := quickRequest("start", map[string]any{"client_id": vortexClientID, "code_challenge": challenge, "code_challenge_method": "S256"})
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if status != 200 {
		return map[string]any{"ok": false, "error": "Red-XAI has not enabled Vortex browser approval yet. Use the existing sign-in option."}
	}
	device, code, link := asString(job["device_code"]), asString(job["user_code"]), asString(job["verification_uri"])
	if !quickSecret.MatchString(device) || !quickCode.MatchString(code) || !checkQuickURL(link) {
		return map[string]any{"ok": false, "error": "Red-XAI returned an unsafe approval request"}
	}
	exp, ok := job["expires_in"].(float64)
	if !ok || exp < 1 || exp > 300 {
		return map[string]any{"ok": false, "error": "Red-XAI returned an invalid approval expiry"}
	}
	interval, ok := job["interval"].(float64)
	if !ok || interval < 2 || interval > 10 {
		return map[string]any{"ok": false, "error": "Red-XAI returned an invalid approval interval"}
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if gen != q.epoch {
		return map[string]any{"ok": false, "error": "Approval cancelled"}
	}
	q.epoch++
	q.approval = quickApproval{code: code, device: device, verifier: verifier, link: link, deadline: time.Now().Add(time.Duration(exp) * time.Second), delay: time.Duration(interval) * time.Second}
	q.polling = false
	return map[string]any{"ok": true, "code": code, "url": link, "interval": int(interval)}
}
func (s *Server) quickPoll() map[string]any {
	q := &s.quickAuth
	q.mu.Lock()
	job := q.approval
	gen := q.epoch
	switch {
	case job.device == "":
		q.mu.Unlock()
		return map[string]any{"ok": false, "error": "Start browser approval first"}
	case time.Now().After(job.deadline):
		q.approval = quickApproval{}
		q.mu.Unlock()
		return map[string]any{"ok": false, "error": "Approval expired; start again"}
	case q.polling || time.Now().Before(job.nextPoll):
		q.mu.Unlock()
		return map[string]any{"ok": true, "pending": true}
	}
	q.polling = true
	q.approval.nextPoll = time.Now().Add(job.delay)
	q.mu.Unlock()
	status, result, err := quickRequest("token", map[string]any{"client_id": vortexClientID, "device_code": job.device, "code_verifier": job.verifier})
	q.mu.Lock()
	q.polling = false
	if gen != q.epoch || q.approval.device != job.device {
		q.mu.Unlock()
		if status == 200 {
			if rf := asString(result["refresh_token"]); rf != "" {
				_, _, _ = quickRequest("revoke", map[string]any{"token": rf})
			}
		}
		return map[string]any{"ok": false, "error": "Approval cancelled"}
	}
	if err != nil {
		q.mu.Unlock()
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if status == 428 {
		q.mu.Unlock()
		return map[string]any{"ok": true, "pending": true}
	}
	if status == 429 {
		q.approval.delay = minQuickDelay(q.approval.delay + time.Second)
		q.approval.nextPoll = time.Now().Add(q.approval.delay)
		q.mu.Unlock()
		return map[string]any{"ok": true, "pending": true}
	}
	if status != 200 {
		q.approval = quickApproval{}
		q.mu.Unlock()
		return map[string]any{"ok": false, "error": "Red-XAI approval was denied or expired"}
	}
	acct, err := parseQuickAccount(result, "")
	if err != nil {
		q.approval = quickApproval{}
		q.mu.Unlock()
		return map[string]any{"ok": false, "error": err.Error()}
	}
	if err = keyring.Set(quickSubjectKey, acct.sub); err == nil {
		err = keyring.Set(quickRefreshKey, acct.refresh)
	}
	if err != nil {
		_ = keyring.Set(quickRefreshKey, "")
		_ = keyring.Set(quickSubjectKey, "")
		q.mu.Unlock()
		_, _, _ = quickRequest("revoke", map[string]any{"token": acct.refresh})
		return map[string]any{"ok": false, "error": "Could not securely save Red-XAI approval"}
	}
	if old := keyring.Get("redx-session"); old != "" {
		_, _ = redxDo("POST", "logout", map[string]string{"X-RedX-Session": old}, map[string]any{})
		_ = keyring.Set("redx-session", "")
	}
	q.account = acct
	q.approval = quickApproval{}
	q.epoch++
	q.mu.Unlock()
	return map[string]any{"ok": true, "signedIn": true}
}
func minQuickDelay(v time.Duration) time.Duration {
	if v > 10*time.Second {
		return 10 * time.Second
	}
	return v
}
func (s *Server) quickCancel() map[string]any {
	s.quickAuth.mu.Lock()
	s.quickAuth.epoch++
	s.quickAuth.approval = quickApproval{}
	s.quickAuth.mu.Unlock()
	return map[string]any{"ok": true}
}
func (s *Server) quickSignedIn() (bool, string, string) {
	q := &s.quickAuth
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.account.access != "" && time.Until(q.account.expires) > 60*time.Second {
		return true, q.account.email, ""
	}
	saved, sub := keyring.Get(quickRefreshKey), keyring.Get(quickSubjectKey)
	if saved == "" || sub == "" {
		return false, "", ""
	}
	status, result, err := quickRequest("refresh", map[string]any{"client_id": vortexClientID, "refresh_token": saved})
	if err != nil {
		return false, "", "Red-XAI is offline; browser approval could not be renewed"
	}
	if status == 401 {
		_ = keyring.Set(quickRefreshKey, "")
		_ = keyring.Set(quickSubjectKey, "")
		q.account = quickAccount{}
		return false, "", "Your Red-XAI approval expired or was revoked"
	}
	if status != 200 {
		return false, "", "Red-XAI approval could not be renewed"
	}
	acct, err := parseQuickAccount(result, sub)
	if err != nil {
		return false, "", "Red-XAI returned an invalid renewed session"
	}
	if keyring.Set(quickRefreshKey, acct.refresh) != nil {
		return false, "", "Failed to store renewed Red-XAI credentials"
	}
	q.account = acct
	return true, acct.email, ""
}
func (s *Server) quickLogout() {
	q := &s.quickAuth
	q.mu.Lock()
	q.epoch++
	q.approval = quickApproval{}
	refresh := keyring.Get(quickRefreshKey)
	_ = keyring.Set(quickRefreshKey, "")
	_ = keyring.Set(quickSubjectKey, "")
	q.account = quickAccount{}
	q.mu.Unlock()
	if refresh != "" {
		_, _, _ = quickRequest("revoke", map[string]any{"token": refresh})
	}
}
