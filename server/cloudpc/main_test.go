package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Each test uses a private authority, ACL and local cookie map. None of these
// fixtures signs in to Accounts or starts a desktop/control process.
func cloudFixture(t *testing.T, authority http.HandlerFunc) *sess {
	t.Helper()
	server := httptest.NewServer(authority)
	t.Cleanup(server.Close)
	oldAcct := acct
	acct = server.URL + "/"
	mu.Lock()
	oldSessions := sessions
	sessions = map[string]*sess{}
	current := &sess{rxs: "fixture-upstream-session", user: "account-a\x00alice", id: "desktop-a", exp: time.Now().Add(time.Hour), touched: time.Now()}
	sessions["fixture-cookie"] = current
	mu.Unlock()
	t.Cleanup(func() {
		acct = oldAcct
		mu.Lock()
		sessions = oldSessions
		mu.Unlock()
	})
	t.Setenv("CPC_ACL", filepath.Join(t.TempDir(), "acl.json"))
	t.Setenv("CPC_OWNERS", "fixture-owner")
	return current
}

func accountResponse(w http.ResponseWriter, id, username string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"account": map[string]any{"id": id, "username": username}})
}

func cloudRequest(method, route string) *http.Request {
	r := httptest.NewRequest(method, "https://cloud.example"+pfx+route, nil)
	r.AddCookie(&http.Cookie{Name: "cpc", Value: "fixture-cookie"})
	r.AddCookie(&http.Cookie{Name: "vx_terms", Value: termsVersion})
	return r
}

func TestSessionRechecksAuthorityAndRejectsChangedIdentity(t *testing.T) {
	for _, test := range []struct {
		name, id, username string
		status             int
	}{
		{"revoked", "", "", http.StatusUnauthorized},
		{"unavailable", "", "", http.StatusServiceUnavailable},
		{"changed subject", "account-b", "alice", http.StatusOK},
		{"changed username", "account-a", "fixture-owner", http.StatusOK},
	} {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Path != "/me" || r.Header.Get("X-RedX-Session") != "fixture-upstream-session" {
					t.Error("unexpected authority request")
				}
				if calls == 1 {
					accountResponse(w, "account-a", "alice")
					return
				}
				w.WriteHeader(test.status)
				if test.status == http.StatusOK {
					accountResponse(w, test.id, test.username)
				}
			})
			r := cloudRequest(http.MethodGet, "/")
			if _, s := getSess(r); s == nil {
				t.Fatal("valid session rejected")
			}
			if token, s := getSess(r); s != nil || token != "" {
				t.Fatal("stale authorization retained")
			}
			mu.Lock()
			_, exists := sessions["fixture-cookie"]
			mu.Unlock()
			if exists || calls != 2 {
				t.Fatalf("session removed=%v, authority calls=%d", !exists, calls)
			}
		})
	}
}

func TestInflightSessionCheckPreservesReplacement(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		http.Error(w, "revoked", http.StatusUnauthorized)
	})
	result := make(chan *sess, 1)
	go func() { _, s := getSess(cloudRequest(http.MethodGet, "/")); result <- s }()
	<-started
	replacement := &sess{rxs: "replacement", user: "account-a\x00alice", exp: time.Now().Add(time.Hour)}
	mu.Lock()
	sessions["fixture-cookie"] = replacement
	mu.Unlock()
	close(release)
	if s := <-result; s != nil {
		t.Fatal("old request accepted replacement session")
	}
	mu.Lock()
	preserved := sessions["fixture-cookie"] == replacement
	mu.Unlock()
	if !preserved {
		t.Fatal("old failed check deleted replacement session")
	}
}

func TestSessionExpiringDuringAuthorityCheckIsRejected(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	current := cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		accountResponse(w, "account-a", "alice")
	})
	result := make(chan *sess, 1)
	go func() { _, s := getSess(cloudRequest(http.MethodGet, "/")); result <- s }()
	<-started
	mu.Lock()
	current.exp = time.Now().Add(-time.Second)
	mu.Unlock()
	close(release)
	if s := <-result; s != nil {
		t.Fatal("expired local session accepted")
	}
}

func TestCloudMutationsRequirePostAndSameOrigin(t *testing.T) {
	authorityCalls := 0
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		authorityCalls++
		accountResponse(w, "account-a", "alice")
	})
	for _, route := range []string{"/request", "/approve", "/deny", "/start", "/stop"} {
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete} {
			r := cloudRequest(method, route)
			r.Header.Set("Origin", "https://cloud.example")
			w := httptest.NewRecorder()
			cloud(w, r)
			if w.Code != http.StatusMethodNotAllowed || w.Header().Get("Allow") != http.MethodPost {
				t.Errorf("%s %s: status=%d Allow=%q", method, route, w.Code, w.Header().Get("Allow"))
			}
		}
		for _, origin := range []string{"", "null", "https://other.example", "http://cloud.example", "https://user@cloud.example", "https://cloud.example/", "https://cloud.example?x=1", "https://cloud.example#fragment"} {
			r := cloudRequest(http.MethodPost, route)
			r.Header.Set("Origin", origin)
			w := httptest.NewRecorder()
			cloud(w, r)
			if w.Code != http.StatusForbidden {
				t.Errorf("POST %s origin=%q: status=%d", route, origin, w.Code)
			}
		}
	}
	if authorityCalls != 0 {
		t.Fatalf("rejected mutation reached authority %d times", authorityCalls)
	}
}

func TestNonOwnerCannotChangeApproval(t *testing.T) {
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	for _, route := range []string{"/approve", "/deny"} {
		r := cloudRequest(http.MethodPost, route)
		r.Header.Set("Origin", "https://cloud.example")
		w := httptest.NewRecorder()
		cloud(w, r)
		if w.Code != http.StatusForbidden {
			t.Errorf("non-owner %s: status=%d", route, w.Code)
		}
	}
}

func TestDesktopRequiresApprovalAndValidSocketOrigin(t *testing.T) {
	current := cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	current.port = "1" // A rejected request must never reach this backend.
	r := cloudRequest(http.MethodGet, "/desktop/vnc_lite.html")
	w := httptest.NewRecorder()
	cloud(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("unapproved desktop: status=%d", w.Code)
	}
	if err := saveACL(aclFile{Approved: []string{"alice"}, Pending: map[string]string{}}); err != nil {
		t.Fatal(err)
	}
	for _, origin := range []string{"", "null", "http://other.example"} {
		r = cloudRequest(http.MethodGet, "/desktop/websockify")
		r.Header.Set("Upgrade", "websocket")
		r.Header.Set("Connection", "Upgrade")
		r.Header.Set("Origin", origin)
		w = httptest.NewRecorder()
		cloud(w, r)
		if w.Code != http.StatusForbidden {
			t.Errorf("websocket origin=%q: status=%d", origin, w.Code)
		}
	}
}

func TestDesktopProxyUsesOnlyCurrentUsersBackendAndStripsCredentials(t *testing.T) {
	current := cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	if err := saveACL(aclFile{Approved: []string{"alice"}, Pending: map[string]string{}}); err != nil {
		t.Fatal(err)
	}
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, header := range []string{"Cookie", "Authorization", "X-RedX-Session", "X-RedX-Flow"} {
			if r.Header.Get(header) != "" {
				t.Errorf("credential header %s reached desktop", header)
			}
		}
		if r.URL.Path != "/vnc_lite.html" || r.URL.RawQuery != "scale=true" {
			t.Errorf("unexpected desktop path %s", r.URL.RequestURI())
		}
		_, _ = io.WriteString(w, "current-user-desktop")
	}))
	defer backend.Close()
	u, _ := url.Parse(backend.URL)
	_, current.port, _ = net.SplitHostPort(u.Host)
	mu.Lock()
	sessions["other-users-cookie"] = &sess{user: "account-b\x00bob", port: "1", exp: time.Now().Add(time.Hour)}
	mu.Unlock()
	r := cloudRequest(http.MethodGet, "/desktop/vnc_lite.html?scale=true")
	r.Header.Set("Authorization", "Bearer fixture")
	r.Header.Set("X-RedX-Session", "untrusted-session")
	r.Header.Set("X-RedX-Flow", "untrusted-flow")
	w := httptest.NewRecorder()
	cloud(w, r)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "current-user-desktop" {
		t.Fatalf("desktop proxy: status=%d body=%q", w.Code, w.Body.String())
	}
}

type trackedCloser struct {
	once   sync.Once
	closed chan struct{}
}

func (c *trackedCloser) Close() error { c.once.Do(func() { close(c.closed) }); return nil }

func TestDesktopAuthorizationWatcherClosesRevokedConnection(t *testing.T) {
	ticks := make(chan time.Time)
	connection := &trackedCloser{closed: make(chan struct{})}
	checked, done := make(chan struct{}), make(chan struct{})
	allowed := true
	go func() {
		watchDesktopAuthorization(context.Background(), ticks, func() bool {
			result := allowed
			checked <- struct{}{}
			return result
		}, connection)
		close(done)
	}()
	ticks <- time.Now()
	<-checked
	select {
	case <-connection.closed:
		t.Fatal("authorized connection closed")
	default:
	}
	allowed = false // The next send synchronizes with the watcher.
	ticks <- time.Now()
	<-checked
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("revoked connection watcher did not terminate")
	}
	select {
	case <-connection.closed:
	default:
		t.Fatal("revoked desktop connection left open")
	}
}

func TestDesktopAuthorizationWatcherStopsWithRequest(t *testing.T) {
	for _, closedTicks := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		ticks, done := make(chan time.Time), make(chan struct{})
		connection := &trackedCloser{closed: make(chan struct{})}
		go func() {
			watchDesktopAuthorization(ctx, ticks, func() bool { t.Error("unexpected authorization check"); return false }, connection)
			close(done)
		}()
		if closedTicks {
			close(ticks)
		} else {
			cancel()
		}
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("watcher did not stop")
		}
		cancel()
	}
}
