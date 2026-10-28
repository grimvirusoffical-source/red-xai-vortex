package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
	"unicode"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/activity"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// Every authenticated account gets an immutable Server/Store pair. A late
// asynchronous response can write only to the profile that started it, never
// to a subsequent user's store. Legacy global data is preserved, not assigned
// to the first person who signs in after upgrading.
func accountProfileID(subject string) (string, error) {
	if strings.TrimSpace(subject) == "" || len(subject) > 256 {
		return "", errors.New("account service returned no stable subject")
	}
	for _, r := range subject {
		if unicode.IsControl(r) {
			return "", errors.New("invalid account subject")
		}
	}
	sum := sha256.Sum256([]byte("https://red-xai.com\x00" + subject))
	return hex.EncodeToString(sum[:]), nil
}

type profileState struct{ stopped atomic.Bool }

func (s *Server) profileLive() bool {
	if s.accountRoot == nil {
		return !s.accountIsolation
	}
	if s.profileState.stopped.Load() {
		return false
	}
	root := s.accountRoot
	root.accountMu.Lock()
	defer root.accountMu.Unlock()
	return root.activeAccount == s && time.Now().Before(root.accountExpires)
}
func (s *Server) accountEpoch() uint64 {
	s.accountMu.Lock()
	defer s.accountMu.Unlock()
	return s.accountGeneration
}

func (s *Server) secretName(name string) string {
	if s.profileID == "" {
		return name
	}
	return "profile-" + s.profileID + "-" + name
}
func (s *Server) secretGet(name string) string {
	if s.accountRoot != nil && name == "redx-session" {
		return s.accountSession
	}
	// Profile-specific names do not match the old environment-variable or
	// globally stored credential fallbacks in the keyring implementation.
	if s.baseCredential != nil {
		return s.baseCredential(s.secretName(name))
	}
	return keyring.Get(s.secretName(name))
}
func (s *Server) secretSet(name, value string) error { return keyring.Set(s.secretName(name), value) }

func (s *Server) activateVerifiedAccount(subject, legacySession string, expires time.Time, epoch uint64) (*Server, error) {
	id, err := accountProfileID(subject)
	if err != nil {
		return nil, err
	}
	s.accountMu.Lock()
	if s.accountGeneration != epoch {
		s.accountMu.Unlock()
		return nil, errors.New("account sign-in was cancelled")
	}
	if s.activeAccount != nil && s.activeAccount.profileID == id && s.activeAccount.accountSession == legacySession && !s.activeAccount.profileState.stopped.Load() {
		s.accountExpires = expires
		p := s.activeAccount
		s.accountMu.Unlock()
		return p, nil
	}
	old := s.activeAccount
	s.activeAccount = nil
	s.accountExpires = time.Time{}
	s.accountMu.Unlock()
	if old != nil {
		old.stopAccountRuntime()
	}
	dir := filepath.Join(s.St.Dir, "Profiles", id)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	// Never follow an account-profile symlink into another user's directory.
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, err
	}
	base, err := filepath.EvalSymlinks(filepath.Join(s.St.Dir, "Profiles"))
	if err != nil {
		return nil, err
	}
	if resolved != filepath.Join(base, id) {
		return nil, errors.New("account profile path is not private")
	}
	p := &Server{St: store.OpenAt(dir), Act: activity.Open(dir), Addr: s.Addr, mux: s.mux,
		accountRoot: s, profileID: id, profileToken: randHex(24), accountSession: legacySession,
		baseCredential: s.baseCredential}
	s.accountMu.Lock()
	if s.accountGeneration != epoch {
		s.accountMu.Unlock()
		return nil, errors.New("account sign-in was cancelled")
	}
	s.activeAccount = p
	s.accountExpires = expires
	s.accountMu.Unlock()
	if s.accountIsolation { // Production only: unit fixtures never start helpers.
		p.applyLink()
		p.applyPhone()
		go p.restoreManagedHosts()
		go p.agentScheduleLoop()
	}
	return p, nil
}
func (s *Server) lockAccount() {
	s.accountMu.Lock()
	s.accountGeneration++
	old := s.activeAccount
	s.activeAccount = nil
	s.accountExpires = time.Time{}
	s.accountMu.Unlock()
	if old != nil {
		old.stopAccountRuntime()
	}
}
func (s *Server) stopAccountRuntime() {
	s.profileState.stopped.Store(true)
	s.pcMu.Lock()
	s.pcEpoch++
	s.pcForceAsk = true
	s.pcMu.Unlock()
	runs.mu.Lock()
	for _, r := range runs.runs {
		if r.server == s && r.Ended.IsZero() && r.cancel != nil {
			r.cancel()
		}
	}
	runs.mu.Unlock()
	s.hostingMu.Lock()
	ids := make([]string, 0, len(s.hosts))
	for id := range s.hosts {
		ids = append(ids, id)
	}
	s.hostingMu.Unlock()
	for _, id := range ids {
		_ = s.stopManagedHost(id, false)
	}
	s.stopMCPConnections()
	// These listeners are one-per-desktop; a new account gets a new PIN and
	// cannot inherit an old phone session or a helper's API-key environment.
	linkMu.Lock()
	if linkProc != nil && linkProc.Process != nil {
		_ = linkProc.Process.Kill()
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
	phone.sessions = nil
	phone.pin = ""
	phone.Unlock()
}
func accountControl(method string) bool {
	return strings.HasPrefix(method, "gate.") || strings.HasPrefix(method, "redx.")
}

// handle is the only HTTP entrypoint. The login screen is not an access-control
// boundary: all data, model, admin and tool routes enforce the account here.
func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	if !s.accountIsolation {
		s.handleProfile(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	method := strings.TrimPrefix(r.URL.Path, "/bridge/")
	phoneSession, _ := r.Context().Value(workspacePhoneSessionKey{}).(bool)
	if !pcLocalOperator(r) && !phoneSession {
		http.Error(w, "local same-origin JSON request required", 403)
		return
	}
	if accountControl(method) {
		if method != "gate.status" && !pcLocalOperator(r) {
			http.Error(w, "account changes require the local operator", 403)
			return
		}
		s.handleProfile(w, r)
		return
	}
	s.accountMu.Lock()
	p, expires := s.activeAccount, s.accountExpires
	s.accountMu.Unlock()
	if p == nil || !time.Now().Before(expires) {
		// No offline grace based merely on the existence of a token.
		_ = s.redx("gate.status", nil)
		s.accountMu.Lock()
		p, expires = s.activeAccount, s.accountExpires
		s.accountMu.Unlock()
	}
	if p == nil || !time.Now().Before(expires) || p.profileState.stopped.Load() {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(401)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "Sign in to your Red-XAI account first.", "accountRequired": true})
		return
	}
	if r.Header.Get("X-Vortex-Profile") != p.profileToken {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(409)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "Account changed. Reload account state before continuing.", "accountChanged": true})
		return
	}
	p.handleProfile(w, r)
}
