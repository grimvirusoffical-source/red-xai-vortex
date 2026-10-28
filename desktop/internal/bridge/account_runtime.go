package bridge

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/activity"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

type accountRuntime struct {
	mu          sync.Mutex
	epoch       uint64
	workspace   *Server
	subject     string
	displayName string
	expires     time.Time
}

func profileIdentifier(subject string) (string, error) {
	if subject == "" || len(subject) > 512 || strings.IndexFunc(subject, func(r rune) bool { return r < 32 || r == 127 }) >= 0 {
		return "", errors.New("the account service did not return a stable subject")
	}
	sum := sha256.Sum256([]byte(vortexAuthOrigin + "\x00" + subject))
	return hex.EncodeToString(sum[:]), nil
}
func accountSubject(account map[string]any) string {
	for _, field := range []string{"sub", "id", "key"} {
		if value, ok := account[field].(string); ok && value != "" {
			return value
		}
	}
	return ""
}
func (s *Server) rootDirectory() string {
	if s.installationDir != "" {
		return s.installationDir
	}
	return s.St.Dir
}
func (s *Server) accountEpoch() uint64 {
	s.accounts.mu.Lock()
	defer s.accounts.mu.Unlock()
	return s.accounts.epoch
}
func isAccountRoute(method string) bool {
	return method == "gate.status" || method == "gate.accept" || strings.HasPrefix(method, "redx.")
}
func (s *Server) activateAccount(subject, name, password string, expires time.Time, epoch uint64) error {
	id, err := profileIdentifier(subject)
	if err != nil {
		return err
	}
	s.accounts.mu.Lock()
	defer s.accounts.mu.Unlock()
	if epoch != s.accounts.epoch {
		return errors.New("sign-in was cancelled by an account change")
	}
	if current := s.accounts.workspace; current != nil && current.profileID == id && !current.profileClosed.Load() {
		s.accounts.expires = expires
		s.accounts.displayName = name
		return nil
	}
	if old := s.accounts.workspace; old != nil {
		old.closeAccountWorkspace()
	}
	profile := store.OpenAt(filepath.Join(s.rootDirectory(), "Profiles", id))
	nonce := make([]byte, 32)
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	workspace := &Server{St: profile, Act: activity.Open(profile.Dir), Addr: s.Addr, mux: s.mux,
		installationDir: s.rootDirectory(), profileID: id, profileLease: hex.EncodeToString(nonce),
		passwordSession: password, profileDone: make(chan struct{})}
	s.accounts.workspace = workspace
	s.accounts.subject = subject
	s.accounts.displayName = name
	s.accounts.expires = expires
	workspace.applyLink()
	workspace.applyPhone()
	go workspace.restoreManagedHosts()
	go workspace.agentScheduleLoop()
	return nil
}
func (s *Server) clearAccountWorkspace() {
	s.accounts.mu.Lock()
	s.accounts.epoch++
	old := s.accounts.workspace
	s.accounts.workspace = nil
	s.accounts.subject = ""
	s.accounts.displayName = ""
	s.accounts.expires = time.Time{}
	if old != nil {
		old.profileClosed.Store(true)
	}
	s.accounts.mu.Unlock()
	if old != nil {
		old.closeAccountWorkspace()
	}
}
func (s *Server) closeAccountWorkspace() {
	s.profileStop.Do(func() {
		s.profileClosed.Store(true)
		if s.profileDone != nil {
			close(s.profileDone)
		}
		_, _ = s.stopPCControl()
		runs.mu.Lock()
		for _, r := range runs.runs {
			if r.server == s && r.cancel != nil {
				r.cancel()
			}
		}
		runs.mu.Unlock()
		s.hostingMu.Lock()
		ids := []string{}
		for id := range s.hosts {
			ids = append(ids, id)
		}
		s.hostingMu.Unlock()
		for _, id := range ids {
			_ = s.stopManagedHost(id, false)
		}
		stopAccountHelpers()
	})
}
func stopAccountHelpers() {
	linkMu.Lock()
	if linkProc != nil && linkProc.Process != nil {
		_ = linkProc.Process.Kill()
		_ = linkProc.Wait()
	}
	linkProc = nil
	linkArgs = ""
	linkErr = ""
	linkMu.Unlock()
	phone.Lock()
	if phone.ln != nil {
		_ = phone.ln.Close()
		phone.ln = nil
	}
	phone.sessions = map[string]time.Time{}
	phone.pin = ""
	phone.fails = 0
	_ = os.Remove(phoneFile())
	phone.Unlock()
}
func (s *Server) credential(account string) string {
	if s.profileClosed.Load() {
		return ""
	}
	if s.profileID == "" { // isolated legacy test fixtures; production broker never executes workspace operations
		return keyring.Get(account)
	}
	if account == "redx-session" {
		return s.passwordSession
	}
	return keyring.GetScoped(s.profileID, account)
}
func (s *Server) saveCredential(account, value string) error {
	if s.profileClosed.Load() {
		return errors.New("account session ended")
	}
	if s.profileID == "" {
		return keyring.Set(account, value)
	}
	return keyring.SetScoped(s.profileID, account, value)
}

// Buffer response until the account lease is rechecked. A long model response
// begun under account A cannot be delivered into account B's browser session.
type accountResponse struct {
	headers http.Header
	status  int
	body    bytes.Buffer
}

func (w *accountResponse) Header() http.Header { return w.headers }
func (w *accountResponse) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *accountResponse) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = 200
	}
	return w.body.Write(b)
}
func (s *Server) handleAccountWorkspace(w http.ResponseWriter, r *http.Request) {
	if !workspaceRequestAllowed(r) {
		pcError(w, 403, "same-origin JSON POST required")
		return
	}
	s.accounts.mu.Lock()
	workspace := s.accounts.workspace
	expires := s.accounts.expires
	s.accounts.mu.Unlock()
	if workspace == nil || workspace.profileClosed.Load() || !time.Now().Before(expires) {
		if workspace != nil && !time.Now().Before(expires) {
			s.clearAccountWorkspace()
		}
		pcError(w, 401, "Sign in to your Red-XAI account before accessing this workspace.")
		return
	}
	if r.Header.Get("X-Vortex-Profile") != workspace.profileLease {
		pcError(w, 401, "Account changed. Refresh your sign-in before accessing workspace data.")
		return
	}
	capture := &accountResponse{headers: make(http.Header)}
	workspace.handle(capture, r)
	s.accounts.mu.Lock()
	valid := s.accounts.workspace == workspace && !workspace.profileClosed.Load()
	s.accounts.mu.Unlock()
	if !valid {
		pcError(w, 401, "The account changed while this operation was running.")
		return
	}
	for key, values := range capture.headers {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	status := capture.status
	if status == 0 {
		status = 200
	}
	w.WriteHeader(status)
	_, _ = w.Write(capture.body.Bytes())
}
func (s *Server) accountGateResult(terms string) map[string]any {
	s.accounts.mu.Lock()
	defer s.accounts.mu.Unlock()
	result := map[string]any{"ok": true, "termsAccepted": terms, "owner": false, "ownerAvailable": false}
	if p := s.accounts.workspace; p != nil && !p.profileClosed.Load() && time.Now().Before(s.accounts.expires) {
		result["signedIn"] = true
		result["username"] = s.accounts.displayName
		result["profileLease"] = p.profileLease
		result["profileID"] = p.profileID
	}
	return result
}

// Used only for redacted diagnostic output. Never return API credentials here.
func (s *Server) accountSummary() []byte {
	data, _ := json.Marshal(s.accountGateResult(""))
	return data
}
