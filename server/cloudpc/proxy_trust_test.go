package main

import (
	"crypto/tls"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func fixtureProxyTrust(t *testing.T, value string) {
	t.Helper()
	policy, err := parseTrustedProxies(value)
	if err != nil {
		t.Fatal(err)
	}
	previous := cpcProxyTrust
	cpcProxyTrust = policy
	t.Cleanup(func() { cpcProxyTrust = previous })
}

func proxyRequest() *http.Request {
	r := httptest.NewRequest(http.MethodGet, "http://cloud.example/vortex/", nil)
	r.RemoteAddr = "127.0.0.1:12345"
	r.Header.Set("CF-Visitor", `{"scheme":"https"}`)
	r.Header.Set("CF-Connecting-IP", "203.0.113.9")
	return r
}

func TestProxyCIDRsAreExplicitAndInvalidConfigurationIsRejected(t *testing.T) {
	fixtureProxyTrust(t, "")
	r := proxyRequest()
	if secure(r) || clientIP(r) != "127.0.0.1" {
		t.Fatal("loopback proxy headers were implicitly trusted")
	}
	for _, value := range []string{"localhost", "127.0.0.1", "127.0.0.1/33", "127.0.0.1/32,", ",::1/128", "::ffff:127.0.0.1/128", strings.Repeat("x", 16385)} {
		if _, err := parseTrustedProxies(value); err == nil {
			t.Errorf("invalid proxy configuration accepted: %q", value[:min(len(value), 80)])
		}
	}
	policy, err := parseTrustedProxies("127.0.0.1/32, ::1/128, 192.0.2.8/24")
	if err != nil {
		t.Fatal(err)
	}
	for _, peer := range []string{"127.0.0.1:4", "[::1]:4", "[::ffff:127.0.0.1]:4", "192.0.2.90:4"} {
		r.RemoteAddr = peer
		if !policy.trusts(r) {
			t.Errorf("configured peer rejected: %s", peer)
		}
	}
	for _, peer := range []string{"127.0.0.2:4", "[::2]:4", "198.51.100.9:4", "127.0.0.1", "invalid", "[fe80::1%adapter]:4"} {
		r.RemoteAddr = peer
		if policy.trusts(r) {
			t.Errorf("unconfigured/malformed peer accepted: %s", peer)
		}
	}
}

func TestProxyHTTPSRequiresTrustedImmediatePeerAndStrictScheme(t *testing.T) {
	fixtureProxyTrust(t, "127.0.0.1/32,::1/128")
	for _, value := range []string{
		"", "https", `{}`, `[]`, `{"scheme":"http"}`, `{"scheme":true}`, `{"Scheme":"https"}`,
		`{"scheme":"https","scheme":"http"}`, `{"scheme":"http","scheme":"https"}`,
		`{"scheme":"https","extra":true}`, `{"scheme":"https"} {}`, `{"scheme":"https"} trailing`,
		" {\"scheme\":\"https\"}", strings.Repeat(" ", 257),
	} {
		r := proxyRequest()
		r.Header.Set("CF-Visitor", value)
		if secure(r) {
			t.Errorf("invalid HTTPS assertion accepted: %q", value)
		}
	}
	r := proxyRequest()
	r.Header.Add("CF-Visitor", `{"scheme":"https"}`)
	if secure(r) {
		t.Fatal("duplicate HTTPS headers accepted")
	}
	for _, value := range []string{`{"scheme":"https"}`, `{ "scheme" : "https" }`} {
		r := proxyRequest()
		r.Header.Set("CF-Visitor", value)
		if !secure(r) {
			t.Fatal("valid configured HTTPS proxy rejected")
		}
		r.RemoteAddr = "198.51.100.8:12345"
		if secure(r) {
			t.Fatal("untrusted direct peer forged HTTPS")
		}
	}
	r = proxyRequest()
	r.RemoteAddr = "198.51.100.8:12345"
	r.Header.Set("CF-Visitor", "malformed")
	r.TLS = &tls.ConnectionState{}
	if !secure(r) {
		t.Fatal("native TLS depended on proxy headers")
	}
}

func TestClientIPTrustsOneValidLiteralOnlyFromConfiguredPeer(t *testing.T) {
	fixtureProxyTrust(t, "127.0.0.1/32")
	for _, check := range []struct{ header, expected string }{
		{"203.0.113.9", "203.0.113.9"}, {"2001:db8::9", "2001:db8::9"}, {"::ffff:203.0.113.9", "203.0.113.9"},
		{"203.0.113.9, 198.51.100.2", "127.0.0.1"}, {"203.0.113.9:443", "127.0.0.1"},
		{"[2001:db8::9]", "127.0.0.1"}, {"fe80::1%adapter", "127.0.0.1"}, {"", "127.0.0.1"}, {" 203.0.113.9", "127.0.0.1"},
	} {
		r := proxyRequest()
		r.Header.Set("CF-Connecting-IP", check.header)
		if actual := clientIP(r); actual != check.expected {
			t.Errorf("header=%q IP=%q, expected %q", check.header, actual, check.expected)
		}
	}
	r := proxyRequest()
	r.Header.Add("CF-Connecting-IP", "203.0.113.9")
	if clientIP(r) != "127.0.0.1" {
		t.Fatal("duplicate IP headers accepted")
	}
	r = proxyRequest()
	r.RemoteAddr = "198.51.100.7:4321"
	r.Header.Set("Forwarded", "for=203.0.113.9;proto=https")
	r.Header.Set("X-Forwarded-For", "203.0.113.9")
	r.Header.Set("X-Forwarded-Proto", "https")
	if secure(r) || clientIP(r) != "198.51.100.7" {
		t.Fatal("untrusted forwarding headers changed the direct connection boundary")
	}
}

type trackedRequestBody struct {
	reader io.Reader
	reads  int
}

func (body *trackedRequestBody) Read(data []byte) (int, error) {
	body.reads++
	return body.reader.Read(data)
}
func (*trackedRequestBody) Close() error { return nil }

func TestPlaintextCredentialHandlersRejectBeforeReadingOrCallingAuthority(t *testing.T) {
	fixtureProxyTrust(t, "")
	var calls atomic.Int32
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		accountResponse(w, "account-a", "alice")
	})
	handlers := []struct {
		name  string
		path  string
		serve http.HandlerFunc
	}{
		{"signin", "/vortex/signin", signin},
		{"signout", "/vortex/signout", signout},
		{"request", pfx + "/request", cloud},
		{"approve", pfx + "/approve", cloud},
		{"deny", pfx + "/deny", cloud},
		{"start", pfx + "/start", cloud},
		{"stop", pfx + "/stop", cloud},
		{"desktop", pfx + "/desktop/websockify", cloud},
	}
	for _, handler := range handlers {
		t.Run(handler.name, func(t *testing.T) {
			body := &trackedRequestBody{reader: strings.NewReader("login=fixture&password=synthetic-fixture-password")}
			r := httptest.NewRequest(http.MethodPost, "http://cloud.example"+handler.path, body)
			r.RemoteAddr = "127.0.0.1:12345"
			r.Header.Set("Origin", "https://cloud.example")
			r.Header.Set("CF-Visitor", `{"scheme":"https"}`)
			r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			r.AddCookie(&http.Cookie{Name: "cpc", Value: "fixture-cookie"})
			w := httptest.NewRecorder()
			handler.serve(w, r)
			if w.Code != http.StatusUpgradeRequired || body.reads != 0 || w.Header().Get("Set-Cookie") != "" || w.Header().Get("Location") != "" {
				t.Fatalf("plaintext handler consumed credentials: status=%d reads=%d", w.Code, body.reads)
			}
		})
	}
	if calls.Load() != 0 {
		t.Fatal("plaintext credentials reached the authority")
	}
}

func TestHTTPSProxyAndNativeTLSRetainWebsiteSessionAndOriginChecks(t *testing.T) {
	fixtureProxyTrust(t, "127.0.0.1/32")
	var calls atomic.Int32
	cloudFixture(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		accountResponse(w, "account-a", "alice")
	})
	for _, nativeTLS := range []bool{false, true} {
		r := cloudRequest(http.MethodGet, "/")
		if !nativeTLS {
			r.TLS = nil
			r.RemoteAddr = "127.0.0.1:12345"
			r.Header.Set("CF-Visitor", `{"scheme":"https"}`)
		}
		r.Header.Set("Origin", "https://cloud.example")
		if !sameOrigin(r) {
			t.Fatal("HTTPS origin rejected on a secure boundary")
		}
		w := httptest.NewRecorder()
		cloud(w, r)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Request Cloud PC access") {
			t.Fatalf("secure website session failed: TLS=%v status=%d", nativeTLS, w.Code)
		}
		r.Header.Set("Origin", "http://cloud.example")
		if sameOrigin(r) {
			t.Fatal("secure boundary accepted an HTTP origin")
		}
	}
	if calls.Load() != 2 {
		t.Fatalf("expected canonical session checks on both secure paths: %d", calls.Load())
	}
}

func TestCleartextSafeRequestsRedirectWithoutSessionUseAndPreservePath(t *testing.T) {
	fixtureProxyTrust(t, "")
	for _, host := range []string{"cloud.example:80", "[2001:db8::1]:80"} {
		for _, method := range []string{http.MethodGet, http.MethodHead} {
			r := httptest.NewRequest(method, "http://"+host+pfx+"/desktop/file%20name?scale=true", nil)
			r.Header.Set("CF-Visitor", `{"scheme":"https"}`)
			w := httptest.NewRecorder()
			if requireSecureBoundary(w, r) || w.Code != http.StatusMovedPermanently {
				t.Fatal("cleartext safe request was accepted")
			}
			expectedHost := strings.TrimSuffix(host, ":80")
			if w.Header().Get("Location") != "https://"+expectedHost+pfx+"/desktop/file%20name?scale=true" {
				t.Fatalf("unsafe or inconsistent HTTPS redirect: %q", w.Header().Get("Location"))
			}
		}
	}
}

func TestNativeAPIStillRequiresNativeTLSEvenWithTrustedHTTPSProxy(t *testing.T) {
	fixtureProxyTrust(t, "127.0.0.1/32")
	calls := 0
	handler := sec(nativeTLSOnly(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer synthetic-fixture-key" {
			t.Error("native API credential changed")
		}
		w.WriteHeader(http.StatusOK)
	})))
	for _, mode := range []string{"direct-http", "trusted-proxy-http", "native-tls"} {
		r := httptest.NewRequest(http.MethodGet, "http://cloud.example/v1/models", nil)
		r.Header.Set("Authorization", "Bearer synthetic-fixture-key")
		r.RemoteAddr = "127.0.0.1:12345"
		if mode == "trusted-proxy-http" {
			r.Header.Set("CF-Visitor", `{"scheme":"https"}`)
		}
		if mode == "native-tls" {
			r.TLS = &tls.ConnectionState{}
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		expected := http.StatusUpgradeRequired
		if mode == "native-tls" {
			expected = http.StatusOK
		}
		if w.Code != expected {
			t.Errorf("mode=%s native API status=%d, expected %d", mode, w.Code, expected)
		}
	}
	if calls != 1 {
		t.Fatalf("native API reached without native TLS: calls=%d", calls)
	}
}
