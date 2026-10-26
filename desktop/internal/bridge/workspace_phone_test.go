package bridge

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestWorkspacePhoneSessionIsRequiredForLANHost(t *testing.T) {
	s := &Server{}
	phone.Lock()
	oldSessions := phone.sessions
	phone.sessions = map[string]time.Time{"workspace-fixture": time.Now().Add(time.Minute)}
	phone.Unlock()
	t.Cleanup(func() { phone.Lock(); phone.sessions = oldSessions; phone.Unlock() })
	h := s.phoneGate(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !workspaceRequestAllowed(r) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	for _, tc := range []struct {
		name, origin string
		cookie       bool
		want         int
	}{
		{"authenticated same-origin phone", "http://192.0.2.1:18192", true, 200},
		{"missing phone session", "http://192.0.2.1:18192", false, 401},
		{"cross-origin phone", "http://attacker.example", true, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "http://192.0.2.1:18192/bridge/workspace.get", strings.NewReader("{}"))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Origin", tc.origin)
			if tc.cookie {
				r.AddCookie(&http.Cookie{Name: "vx_phone", Value: "workspace-fixture"})
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("got %d want %d", w.Code, tc.want)
			}
		})
	}
	r := httptest.NewRequest(http.MethodPost, "http://192.0.2.1:18192/bridge/workspace.get", strings.NewReader("{}"))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "http://192.0.2.1:18192")
	if workspaceRequestAllowed(r) {
		t.Fatal("LAN host bypassed phone gate")
	}
}
