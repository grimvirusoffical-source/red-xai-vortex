package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestAmbiguousSessionCookiesDenyRequestBeforeAuthorityWithoutDeletingSessions(t *testing.T) {
	var calls atomic.Int32
	current := cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		accountResponse(w, "account-a", "alice")
	})
	valid := func() {
		w := httptest.NewRecorder()
		cloud(w, cloudRequest(http.MethodGet, "/"))
		if w.Code != http.StatusOK {
			t.Fatalf("valid existing session denied: %d", w.Code)
		}
	}
	valid()
	if calls.Load() != 1 {
		t.Fatal("valid session did not reach canonical authority")
	}
	for _, headers := range [][]string{
		{"cpc=fixture-cookie; cpc=unknown-cookie"},
		{"cpc=unknown-cookie; cpc=fixture-cookie"},
		{"cpc=fixture-cookie; cpc=fixture-cookie"},
		{"cpc=fixture-cookie", "cpc=unknown-cookie"},
		{"cpc; cpc=fixture-cookie"},
		{"cpc=\"invalid cookie value\"; cpc=fixture-cookie"},
	} {
		r := cloudRequest(http.MethodGet, "/")
		r.Header.Del("Cookie")
		for _, header := range headers {
			r.Header.Add("Cookie", header)
		}
		w := httptest.NewRecorder()
		cloud(w, r)
		if w.Code != http.StatusSeeOther || !strings.HasPrefix(w.Header().Get("Location"), "/vortex/signin?") || calls.Load() != 1 {
			t.Fatalf("ambiguous cookie reached authority or gained access: status=%d calls=%d", w.Code, calls.Load())
		}
		mu.Lock()
		preserved := sessions["fixture-cookie"] == current
		mu.Unlock()
		if !preserved {
			t.Fatal("ambiguous request deleted the existing valid session")
		}
	}
	valid()
	if calls.Load() != 2 {
		t.Fatal("valid session stopped working after ambiguous requests")
	}
}

func TestAmbiguousFlowCookiesDenyChallengeBeforeAuthorityWithoutDeletingFlows(t *testing.T) {
	var calls atomic.Int32
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/login/call" || r.Header.Get("X-RedX-Flow") != "synthetic-flow-a" {
			t.Error("unexpected challenge or selected flow")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	first := &pend{flow: "synthetic-flow-a", call: true, next: "/vortex/", exp: time.Now().Add(time.Hour)}
	second := &pend{flow: "synthetic-flow-b", call: true, next: "/vortex/", exp: time.Now().Add(time.Hour)}
	mu.Lock()
	previous := pending
	pending = map[string]*pend{"fixture-flow-a": first, "fixture-flow-b": second}
	mu.Unlock()
	t.Cleanup(func() { mu.Lock(); pending = previous; mu.Unlock() })
	request := func(headers []string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "https://cloud.example/vortex/signin", strings.NewReader("step=call"))
		r.Header.Set("Origin", "https://cloud.example")
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		for _, header := range headers {
			r.Header.Add("Cookie", header)
		}
		w := httptest.NewRecorder()
		signin(w, r)
		return w
	}
	if w := request([]string{"cpcf=fixture-flow-a; unrelated=one; unrelated=two"}); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Calling you now.") || calls.Load() != 1 {
		t.Fatal("valid unique challenge flow did not work")
	}
	for _, headers := range [][]string{
		{"cpcf=fixture-flow-a; cpcf=fixture-flow-b"},
		{"cpcf=fixture-flow-b; cpcf=fixture-flow-a"},
		{"cpcf=fixture-flow-a; cpcf=fixture-flow-a"},
		{"cpcf=fixture-flow-a", "cpcf=fixture-flow-b"},
		{"cpcf; cpcf=fixture-flow-a"},
	} {
		w := request(headers)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "This sign-in has expired.") || calls.Load() != 1 || w.Header().Get("Set-Cookie") != "" {
			t.Fatal("ambiguous challenge selected a flow, called authority or issued a cookie")
		}
		mu.Lock()
		preserved := pending["fixture-flow-a"] == first && pending["fixture-flow-b"] == second
		mu.Unlock()
		if !preserved {
			t.Fatal("ambiguous challenge deleted or replaced an existing flow")
		}
	}
	if w := request([]string{"cpcf=fixture-flow-a"}); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Calling you now.") || calls.Load() != 2 {
		t.Fatal("valid flow stopped working after ambiguous challenges")
	}
}
