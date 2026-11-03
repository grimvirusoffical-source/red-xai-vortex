package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/smtp"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const pfx = "/vortex/cloudpc"

type sess struct {
	rxs     string
	user    string
	account accountIdentity
	checked time.Time
	id      string
	port    string
	exp     time.Time
	touched time.Time
}

var (
	mu       sync.Mutex
	sessions = map[string]*sess{}
	fails    = map[string][]time.Time{}
	www      = env("CPC_WWW", "/srv/cloudpc-web/www")
	acct     = env("CPC_ACCT", "https://api.red-xai.com/v1/accounts/")
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// Cloud PC access binds to canonical account IDs. An exact private owner-ID
// allowlist additionally requires the authority's owner role and completed MFA.

type aclFile struct {
	Schema    int               `json:"schema"`
	Approved  []string          `json:"approved"`
	Pending   map[string]string `json:"pending"` // immutable account ID -> requested_at
	Audit     []aclAudit        `json:"audit"`
	AuditHead string            `json:"audit_head,omitempty"`
}

func aclPath() string { return env("CPC_ACL", "/var/lib/cloudpc/acl.json") }

func isOwner(s *sess) bool {
	return s != nil && s.account.Owner && time.Now().UnixMilli() < s.account.ExpiresMs
}

func usernameOf(s *sess) string {
	parts := strings.SplitN(s.user, "\x00", 2)
	if len(parts) == 2 {
		return parts[1]
	}
	return s.user
}

func isApproved(s *sess) bool {
	if s == nil || !validAccountID(s.account.ID) || time.Now().UnixMilli() >= s.account.ExpiresMs {
		return false
	}
	if isOwner(s) {
		return true
	}
	a, err := loadACL()
	if err != nil {
		return false
	}
	for _, x := range a.Approved {
		if x == s.account.ID {
			return true
		}
	}
	return false
}

func limited(ip string) bool {
	mu.Lock()
	defer mu.Unlock()
	var keep []time.Time
	for _, t := range fails[ip] {
		if time.Since(t) < 15*time.Minute {
			keep = append(keep, t)
		}
	}
	fails[ip] = keep
	return len(keep) >= 8
}

func fail(ip string) { mu.Lock(); fails[ip] = append(fails[ip], time.Now()); mu.Unlock() }

func acctCall(route, flow, session string, body any) (int, map[string]any) {
	var rd io.Reader
	method := "GET"
	if body != nil {
		bb, _ := json.Marshal(body)
		rd = bytes.NewReader(bb)
		method = "POST"
	}
	req, err := http.NewRequest(method, acct+route, rd)
	if err != nil {
		return 503, map[string]any{}
	}
	req.Header.Set("accept", "application/json")
	req.Header.Set("content-type", "application/json")
	if flow != "" {
		req.Header.Set("X-RedX-Flow", flow)
	}
	if session != "" {
		req.Header.Set("X-RedX-Session", session)
	}
	c := &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := c.Do(req)
	if err != nil {
		return 503, map[string]any{"message": "RedX accounts are not reachable right now."}
	}
	defer res.Body.Close()
	m := map[string]any{}
	data, err := io.ReadAll(io.LimitReader(res.Body, (1<<16)+1))
	if err != nil || len(data) > 1<<16 || strings.TrimSpace(strings.SplitN(res.Header.Get("Content-Type"), ";", 2)[0]) != "application/json" {
		return 503, map[string]any{}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&m); err != nil || m == nil {
		return 503, map[string]any{}
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return 503, map[string]any{}
	}
	return res.StatusCode, m
}

func str(m map[string]any, k string) string { v, _ := m[k].(string); return v }

func meOf(rxs string) (accountIdentity, bool) {
	st, m := acctCall("me", "", rxs, nil)
	if st != 200 {
		return accountIdentity{}, false
	}
	return canonicalAccount(m, time.Now())
}

func getSess(r *http.Request) (string, *sess) {
	c, err := uniqueCookie(r, "cpc")
	if err != nil {
		return "", nil
	}
	mu.Lock()
	defer mu.Unlock()
	s := sessions[c.Value]
	if s == nil || time.Now().After(s.exp) {
		delete(sessions, c.Value)
		return "", nil
	}
	// A local Cloud PC cookie must not outlive revocation at Accounts. Also
	// reject a changed subject or username instead of retaining stale rights.
	rxs, expected := s.rxs, s.account
	mu.Unlock()
	who, ok := meOf(rxs)
	mu.Lock()
	if sessions[c.Value] != s {
		return "", nil
	}
	if !ok || who.ID != expected.ID || who.Username != expected.Username || who.Owner != expected.Owner || time.Now().After(s.exp) {
		delete(sessions, c.Value)
		return "", nil
	}
	s.checked = time.Now()
	return c.Value, s
}

func run(asUser string, args ...string) (string, error) {
	a := []string{"-n"}
	if asUser != "" {
		a = append(a, "-u", asUser)
	}
	out, err := exec.Command("sudo", append(a, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}

var page = template.Must(template.New("p").Parse(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Red-XAI Cloud PC</title><link rel="stylesheet" href="/vortex/style.css"></head><body><main class="wrap">
<a href="/vortex/" class="back">&larr; Red-XAI Vortex</a><h1>Cloud PC</h1>
<p class="sub">A private Linux desktop in your browser. Sandboxed, 2 vCPU, 3 GB RAM, 5 GB personal storage. Idle desktops shut down after 2 hours; your files are kept.</p>
{{if .Msg}}<p class="msg">{{.Msg}}</p>{{end}}
{{if .Owner}}<p class="sub">Signed in as owner ({{.User}}). Access is auto-approved.</p>{{end}}
{{if .Approved}}
<form method="post" action="` + pfx + `/start"><button class="btn">Open my desktop</button></form>
<form method="post" action="` + pfx + `/stop"><button class="btn ghost">Shut down desktop</button></form>
{{else}}
<p class="sub">Cloud PC access needs owner approval. {{if .Pending}}Your request is pending.{{else}}Request access below.{{end}}</p>
{{if not .Pending}}<form method="post" action="` + pfx + `/request"><button class="btn">Request Cloud PC access</button></form>{{end}}
{{end}}
{{if .Owner}}
<section class="card" style="margin-top:1.5rem"><h2>Pending requests</h2>
{{if .PendingList}}{{range .PendingList}}
<form method="post" action="` + pfx + `/approve" style="display:inline-flex;gap:.5rem;align-items:center;margin:.4rem 0">
<input type="hidden" name="account_id" value="{{.}}"><span>{{.}}</span>
<button class="btn">Approve</button></form>
<form method="post" action="` + pfx + `/deny" style="display:inline-flex;gap:.5rem;align-items:center;margin:.4rem 0">
<input type="hidden" name="account_id" value="{{.}}">
<button class="btn ghost">Deny</button></form>
{{end}}{{else}}<p class="sub small">No pending requests.</p>{{end}}
</section>
<section class="card" style="margin-top:1rem"><h2>Approved users</h2>
{{if .ApprovedList}}{{range .ApprovedList}}
<form method="post" action="` + pfx + `/deny" style="display:flex;gap:.5rem;align-items:center;margin:.4rem 0">
<input type="hidden" name="account_id" value="{{.}}"><span>{{.}}</span>
<button class="btn ghost">Revoke</button></form>
{{end}}{{else}}<p class="sub small">No approved non-owner users.</p>{{end}}
</section>
{{end}}
<form method="post" action="/vortex/signout"><button class="link">Sign out</button></form>
</main></body></html>`))

func render(w http.ResponseWriter, s *sess, msg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	u := ""
	owner, approved, pending := false, false, false
	var pendingList, approvedList []string
	if s != nil {
		u = usernameOf(s)
		owner = isOwner(s)
		approved = isApproved(s)
		a, err := loadACL()
		if err != nil {
			http.Error(w, "Cloud PC permissions are temporarily unavailable.", http.StatusServiceUnavailable)
			return
		}
		_, pending = a.Pending[s.account.ID]
		if owner {
			for k := range a.Pending {
				pendingList = append(pendingList, k)
			}
			approvedList = append(approvedList, a.Approved...)
		}
	}
	page.Execute(w, map[string]any{"Msg": msg, "User": u, "Owner": owner, "Approved": approved, "Pending": pending, "PendingList": pendingList, "ApprovedList": approvedList})
}

func sameOrigin(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" || o == "null" {
		return false
	}
	u, err := url.Parse(o)
	scheme := "http"
	if secure(r) {
		scheme = "https"
	}
	return err == nil && u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == "" &&
		strings.EqualFold(u.Host, r.Host) && u.Scheme == scheme
}

func cloud(w http.ResponseWriter, r *http.Request) {
	if !requireSecureBoundary(w, r) {
		return
	}
	p := strings.TrimPrefix(r.URL.Path, pfx)
	switch p {
	case "/request", "/approve", "/deny", "/start", "/stop":
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
	}
	if r.Method == http.MethodPost && !sameOrigin(r) {
		http.Error(w, "bad origin", http.StatusForbidden)
		return
	}
	tok, s := getSess(r)
	if s != nil && !termsOK(w, r) {
		return
	}
	if strings.HasPrefix(p, "/desktop/") {
		if s == nil {
			toSignin(w, r)
			return
		}
		if !isApproved(s) {
			http.Error(w, "Cloud PC access is not approved.", http.StatusForbidden)
			return
		}
		if (r.Header.Get("Origin") != "" || strings.EqualFold(r.Header.Get("Upgrade"), "websocket")) && !sameOrigin(r) {
			http.Error(w, "bad origin", http.StatusForbidden)
			return
		}
		mu.Lock()
		if s.port == "" {
			mu.Unlock()
			http.Redirect(w, r, pfx+"/", 303)
			return
		}
		if time.Since(s.touched) > time.Minute {
			s.touched = time.Now()
			go run("cloudpc", "/usr/local/sbin/cloudpc-ctl", "touch", s.id)
		}
		port := s.port
		mu.Unlock()
		t, _ := url.Parse("http://127.0.0.1:" + port)
		rp := httputil.NewSingleHostReverseProxy(t)
		rp.FlushInterval = -1
		// An established desktop socket must also lose access when its website
		// session or Cloud PC approval is revoked, without waiting for reconnect.
		sessionRequest := &http.Request{Header: make(http.Header)}
		sessionRequest.AddCookie(&http.Cookie{Name: "cpc", Value: tok})
		rp.ModifyResponse = func(response *http.Response) error {
			if response.StatusCode == http.StatusSwitchingProtocols {
				go func() {
					ticker := time.NewTicker(30 * time.Second)
					defer ticker.Stop()
					watchDesktopAuthorization(r.Context(), ticker.C, func() bool {
						_, current := getSess(sessionRequest)
						return current == s && isApproved(current)
					}, response.Body)
				}()
			}
			return nil
		}
		rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("desktop proxy: %v", err)
			http.Error(w, "desktop unreachable", 502)
		}
		r.URL.Path = strings.TrimPrefix(p, "/desktop")
		if r.URL.Path == "" {
			r.URL.Path = "/"
		}
		r.Header.Del("Cookie")
		r.Header.Del("Authorization")
		r.Header.Del("X-RedX-Session")
		r.Header.Del("X-RedX-Flow")
		r.Host = "127.0.0.1:" + port
		rp.ServeHTTP(w, r)
		return
	}
	if s == nil {
		toSignin(w, r)
		return
	}
	_ = tok
	switch p {
	case "", "/":
		if p == "" {
			http.Redirect(w, r, pfx+"/", 301)
			return
		}
		render(w, s, "")
	case "/request":
		u := s.account.ID
		if isApproved(s) {
			render(w, s, "You already have access.")
			return
		}
		capacityFull := false
		changed, err := mutateACLWhen(func(a *aclFile) bool {
			if _, exists := a.Pending[u]; exists {
				return false
			}
			for _, id := range a.Approved {
				if id == u {
					return false
				}
			}
			a.Pending[u] = time.Now().UTC().Format(time.RFC3339)
			a.record("request", u, u)
			if data, err := json.MarshalIndent(a, "", "  "); err != nil || len(data) > maxACLBytes-aclRequestReserve {
				capacityFull = true
				return false
			}
			return true
		})
		if err != nil {
			http.Error(w, "Could not save Cloud PC permissions. No request was acknowledged.", http.StatusServiceUnavailable)
			return
		}
		if capacityFull {
			http.Error(w, "Cloud PC request capacity is temporarily unavailable. No request was saved.", http.StatusServiceUnavailable)
			return
		}
		if !changed {
			render(w, s, "Your access is already approved or requested.")
			return
		}
		ownerAlert(u)
		render(w, s, "Access requested. The owner has been notified.")
	case "/approve":
		if !isOwner(s) {
			http.Error(w, "forbidden", 403)
			return
		}
		u := r.FormValue("account_id")
		if !validAccountID(u) {
			render(w, s, "Missing user.")
			return
		}
		if err := mutateACL(func(a *aclFile) {
			delete(a.Pending, u)
			found := false
			for _, x := range a.Approved {
				if x == u {
					found = true
					break
				}
			}
			if !found {
				a.Approved = append(a.Approved, u)
			}
			a.record("approve", s.account.ID, u)
		}); err != nil {
			http.Error(w, "Could not save Cloud PC permissions. Approval was not acknowledged.", http.StatusServiceUnavailable)
			return
		}
		// The legacy notification gateway routes user:<username> by mutable key
		// names. Do not send a private decision until an ID-bound recipient
		// contract is verified; the saved decision remains visible in Cloud PC.
		render(w, s, "Approved "+u+".")
	case "/deny":
		if !isOwner(s) {
			http.Error(w, "forbidden", 403)
			return
		}
		u := r.FormValue("account_id")
		if !validAccountID(u) {
			render(w, s, "Missing user.")
			return
		}
		if err := mutateACL(func(a *aclFile) {
			delete(a.Pending, u)
			kept := a.Approved[:0]
			for _, x := range a.Approved {
				if x != u {
					kept = append(kept, x)
				}
			}
			a.Approved = kept
			a.record("deny", s.account.ID, u)
		}); err != nil {
			http.Error(w, "Could not save Cloud PC permissions. Revocation was not acknowledged.", http.StatusServiceUnavailable)
			return
		}
		render(w, s, "Denied/revoked "+u+".")
	case "/start":
		if s == nil {
			http.Redirect(w, r, pfx+"/", 303)
			return
		}
		if !isApproved(s) {
			render(w, s, "Cloud PC access is not approved yet. Request access first.")
			return
		}
		if _, err := run("", "/usr/local/sbin/cloudpc-home", s.id); err != nil {
			render(w, s, "Could not prepare storage.")
			return
		}
		port, err := run("cloudpc", "/usr/local/sbin/cloudpc-ctl", "start", s.id)
		if err != nil || port == "" {
			render(w, s, "All Cloud PCs are busy right now. Try again soon.")
			return
		}
		run("cloudpc", "/usr/local/sbin/cloudpc-ctl", "touch", s.id)
		mu.Lock()
		s.port = port
		mu.Unlock()
		time.Sleep(3 * time.Second)
		http.Redirect(w, r, pfx+"/desktop/vnc_lite.html?scale=true&path="+url.QueryEscape(strings.TrimPrefix(pfx, "/")+"/desktop/websockify"), 303)
	case "/stop":
		if s != nil {
			run("cloudpc", "/usr/local/sbin/cloudpc-ctl", "stop", s.id)
			mu.Lock()
			s.port = ""
			mu.Unlock()
		}
		render(w, s, "Desktop shut down.")
	default:
		http.NotFound(w, r)
	}
}

func watchDesktopAuthorization(ctx context.Context, ticks <-chan time.Time, allowed func() bool, connection io.Closer) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-ticks:
			if !ok {
				return
			}
			if !allowed() {
				_ = connection.Close()
				return
			}
		}
	}
}

func sec(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		if !strings.HasPrefix(r.URL.Path, pfx+"/desktop/") {
			w.Header().Set("X-Frame-Options", "DENY")
		}
		// The native API retains its stricter, handler-enforced native-TLS
		// requirement, even when a trusted HTTPS proxy serves the website.
		if !strings.HasPrefix(r.URL.Path, "/v1/") && !requireSecureBoundary(w, r) {
			return
		}
		h.ServeHTTP(w, r)
	})
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "prepare-acl-migration" {
		if err := prepareACLMigration(os.Args[2:]); err != nil {
			log.Fatal(err)
		}
		log.Print("Prepared a separate review ACL; original permissions are unchanged. Verify mapping provenance before promotion.")
		return
	}
	ownerIDs, err := parseOwnerAccountIDs(os.Getenv("CPC_OWNER_ACCOUNT_IDS"))
	if err != nil {
		log.Fatal(err)
	}
	cpcOwnerIDs = ownerIDs
	policy, err := parseTrustedProxies(os.Getenv("CPC_TRUSTED_PROXY_CIDRS"))
	if err != nil {
		log.Fatal(err)
	}
	cpcProxyTrust = policy
	m := http.NewServeMux()
	m.HandleFunc(pfx, cloud)
	m.HandleFunc(pfx+"/", cloud)
	fs := http.StripPrefix("/vortex/", http.FileServer(http.Dir(www)))
	m.HandleFunc("/vortex/signin", signin)
	m.HandleFunc("/vortex/signout", signout)
	m.HandleFunc("/vortex/", func(w http.ResponseWriter, r *http.Request) {
		// Public: stylesheet + desktop download artifacts (SHA256SUMS, installers).
		if r.URL.Path == "/vortex/donate" || r.URL.Path == "/vortex/terms" {
			http.Redirect(w, r, r.URL.Path+"/"+qs(r), 301)
			return
		}
		// Public: stylesheet, downloads, donate and terms pages.
		if r.URL.Path == "/vortex/style.css" || strings.HasPrefix(r.URL.Path, "/vortex/download/") ||
			strings.HasPrefix(r.URL.Path, "/vortex/donate/") || strings.HasPrefix(r.URL.Path, "/vortex/terms/") {
			fs.ServeHTTP(w, r)
			return
		}
		if _, s := getSess(r); s == nil {
			toSignin(w, r)
			return
		}
		if !termsOK(w, r) {
			return
		}
		if strings.HasSuffix(r.URL.Path, "/") && r.URL.Path != "/vortex/" {
			if _, err := os.Stat(www + strings.TrimPrefix(r.URL.Path, "/vortex") + "index.html"); err != nil {
				http.NotFound(w, r)
				return
			}
		}
		fs.ServeHTTP(w, r)
	})
	// Public OpenAI-compatible API for desktop apps (gateway enforces API keys).
	gwURL, _ := url.Parse(env("CPC_GATEWAY", "http://127.0.0.1:8091"))
	gwp := httputil.NewSingleHostReverseProxy(gwURL)
	gwp.FlushInterval = -1
	m.Handle("/v1/", nativeTLSOnly(gwp))
	// Plugin store (127.0.0.1:8095). /plugins/ is the public API for the apps (RedX session via
	// X-RedX-Session header). /vortex/store-api/ is the same API for the signed-in web "My plugins"
	// page: it injects the web session's RedX token and requires X-Requested-With on writes (CSRF).
	psURL, _ := url.Parse(env("CPC_PLUGINSTORE", "http://127.0.0.1:8095"))
	psp := httputil.NewSingleHostReverseProxy(psURL)
	m.Handle("/plugins/", http.StripPrefix("/plugins", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil && r.Method != "GET" {
			http.Error(w, `{"error":"use https"}`, http.StatusUpgradeRequired)
			return
		}
		r.Header.Del("Cookie")
		psp.ServeHTTP(w, r)
	})))
	m.Handle("/vortex/store-api/", http.StripPrefix("/vortex/store-api", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, s := getSess(r)
		if s == nil {
			http.Error(w, `{"error":"You must sign in to Red-XAI first."}`, 401)
			return
		}
		if r.Method != "GET" && r.Header.Get("X-Requested-With") != "vortex" {
			http.Error(w, `{"error":"bad request"}`, 403)
			return
		}
		r.Header.Del("Cookie")
		mu.Lock()
		r.Header.Set("X-RedX-Session", s.rxs)
		mu.Unlock()
		psp.ServeHTTP(w, r)
	})))
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/vortex/", 302) })
	h := sec(m)
	go func() {
		s := &http.Server{Addr: env("CPC_HTTP", ":80"), Handler: h, ReadHeaderTimeout: 10 * time.Second}
		log.Fatal(s.ListenAndServe())
	}()
	s := &http.Server{Addr: env("CPC_HTTPS", ":443"), Handler: h, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(s.ListenAndServeTLS(env("CPC_CERT", "/etc/cloudpc-web/cert.pem"), env("CPC_KEY", "/etc/cloudpc-web/key.pem")))
}

type pend struct {
	flow string
	totp bool
	call bool
	next string
	exp  time.Time
}

var pending = map[string]*pend{}

func safeNext(n string) string {
	if !strings.HasPrefix(n, "/vortex") || strings.HasPrefix(n, "//") || strings.ContainsAny(n, "\\\r\n") || strings.HasPrefix(n, "/vortex/signin") {
		return "/vortex/"
	}
	return n
}

func toSignin(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/vortex/signin?next="+url.QueryEscape(r.URL.RequestURI()), 303)
}

var signPage = template.Must(template.New("s").Parse(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in · Red-XAI Vortex</title><link rel="stylesheet" href="/vortex/style.css"></head><body><main class="wrap narrow">
<a href="https://red-xai.com/" class="back">&larr; Red-XAI</a><h1>Sign in to <span>RedX</span></h1>
<p class="sub">Use your RedX account to open Red-XAI Vortex and Cloud PC.</p>
{{if .Msg}}<p class="msg">{{.Msg}}</p>{{end}}
{{if .TwoFA}}<form method="post" action="/vortex/signin" class="card"><input type="hidden" name="step" value="2fa">
<label>{{if .Totp}}6-digit code from your authenticator app{{else}}Code read out on the call{{end}}<input name="code" inputmode="numeric" autocomplete="one-time-code" required></label>
<input type="hidden" name="method" value="{{if .Totp}}totp{{else}}call{{end}}">
<button class="btn">Verify</button>{{if .Call}}<button class="btn ghost" name="step" value="call" formnovalidate>Call me with a code</button>{{end}}</form>
{{else}}<form method="post" action="/vortex/signin" class="card"><input type="hidden" name="next" value="{{.Next}}">
<label>Username or email<input name="login" autocomplete="username" required></label>
<label>Password<input type="password" name="password" autocomplete="current-password" required></label>
<button class="btn">Continue</button></form>
<p class="sub small">New to RedX? <a href="https://red-xai.com/signup">Create an account</a> · <a href="https://red-xai.com/signin">Forgot password?</a></p>{{end}}
</main></body></html>`))

func signin(w http.ResponseWriter, r *http.Request) {
	if !requireSecureBoundary(w, r) {
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	show := func(d map[string]any) { signPage.Execute(w, d) }
	if r.Method != "POST" {
		if _, s := getSess(r); s != nil {
			http.Redirect(w, r, safeNext(r.URL.Query().Get("next")), 303)
			return
		}
		show(map[string]any{"Next": safeNext(r.URL.Query().Get("next"))})
		return
	}
	if !sameOrigin(r) {
		http.Error(w, "bad origin", 403)
		return
	}
	ip := clientIP(r)
	if limited(ip) {
		show(map[string]any{"Msg": "Too many attempts. Try again later."})
		return
	}
	step := r.FormValue("step")
	if step == "2fa" || step == "call" {
		c, err := uniqueCookie(r, "cpcf")
		mu.Lock()
		var p *pend
		if err == nil {
			p = pending[c.Value]
		}
		mu.Unlock()
		if p == nil || time.Now().After(p.exp) {
			show(map[string]any{"Msg": "This sign-in has expired. Start again.", "Next": "/vortex/"})
			return
		}
		d := map[string]any{"TwoFA": true, "Totp": p.totp, "Call": p.call && !p.totp}
		if step == "call" {
			st, m := acctCall("login/call", p.flow, "", map[string]any{})
			if st == 200 {
				d["Msg"] = "Calling you now."
				d["Totp"] = false
			} else {
				d["Msg"] = orMsg(m, "The call could not be placed.")
			}
			show(d)
			return
		}
		method := "totp"
		if r.FormValue("method") == "call" {
			method = "call"
		}
		st, m := acctCall("login/2fa", p.flow, "", map[string]any{"method": method, "code": strings.TrimSpace(r.FormValue("code"))})
		if token := completedToken(m); st == 200 && token != "" {
			mu.Lock()
			delete(pending, c.Value)
			mu.Unlock()
			finish(w, r, token, p.next)
			return
		}
		fail(ip)
		if st == 401 {
			show(map[string]any{"Msg": "This sign-in has expired. Start again.", "Next": p.next})
			return
		}
		d["Msg"] = orMsg(m, "That code is not right.")
		show(d)
		return
	}
	next := safeNext(r.FormValue("next"))
	st, m := acctCall("login", "", "", map[string]any{"login": strings.TrimSpace(r.FormValue("login")), "password": r.FormValue("password")})
	if st != 200 {
		fail(ip)
		show(map[string]any{"Msg": orMsg(m, "Sign-in failed."), "Next": next})
		return
	}
	switch str(m, "next") {
	case "2fa":
		meth, _ := m["methods"].(map[string]any)
		totp, _ := meth["totp"].(bool)
		call, _ := meth["call"].(bool)
		b, err := randBytes(32)
		if err != nil {
			http.Error(w, "error", 500)
			return
		}
		t := hex.EncodeToString(b)
		mu.Lock()
		pending[t] = &pend{flow: str(m, "token"), totp: totp, call: call, next: next, exp: time.Now().Add(10 * time.Minute)}
		mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "cpcf", Value: t, Path: "/vortex/signin", HttpOnly: true, Secure: secure(r), SameSite: http.SameSiteStrictMode, MaxAge: 600})
		show(map[string]any{"TwoFA": true, "Totp": totp, "Call": call && !totp})
	case "2fa_setup":
		show(map[string]any{"Msg": "Finish setting up two-step sign-in on red-xai.com first, then come back.", "Next": next})
	default:
		if token := completedToken(m); token != "" {
			finish(w, r, token, next)
			return
		}
		show(map[string]any{"Msg": "Sign-in failed.", "Next": next})
	}
}

func orMsg(m map[string]any, d string) string {
	if v := str(m, "message"); v != "" && len(v) < 200 {
		return v
	}
	return d
}

func finish(w http.ResponseWriter, r *http.Request, rxs, next string) {
	who, ok := meOf(rxs)
	if !ok {
		signPage.Execute(w, map[string]any{"Msg": "Sign-in failed.", "Next": next})
		return
	}
	h := sum256([]byte("cloudpc-redx:" + who.ID))
	b, err := randBytes(32)
	if err != nil {
		http.Error(w, "error", 500)
		return
	}
	t := hex.EncodeToString(b)
	mu.Lock()
	expires := time.Now().Add(12 * time.Hour)
	if canonicalExpiry := time.UnixMilli(who.ExpiresMs); canonicalExpiry.Before(expires) {
		expires = canonicalExpiry
	}
	sessions[t] = &sess{rxs: rxs, user: who.ID + "\x00" + who.Username, account: who, checked: time.Now(), id: hex.EncodeToString(h[:8]), exp: expires}
	mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "cpc", Value: t, Path: "/vortex", HttpOnly: true, Secure: secure(r), SameSite: http.SameSiteLaxMode, MaxAge: 43200})
	http.Redirect(w, r, next, 303)
}

func signout(w http.ResponseWriter, r *http.Request) {
	if !requireSecureBoundary(w, r) {
		return
	}
	if r.Method == "POST" && sameOrigin(r) {
		if tok, s := getSess(r); s != nil {
			go acctCall("logout", "", s.rxs, map[string]any{})
			mu.Lock()
			delete(sessions, tok)
			mu.Unlock()
		}
		http.SetCookie(w, &http.Cookie{Name: "cpc", Value: "", Path: "/vortex", MaxAge: -1})
	}
	http.Redirect(w, r, "/vortex/signin", 303)
}

// Web Terms of Service gate: signed-in pages require the current terms to be
// accepted (cookie set by /vortex/terms/). A new version re-prompts.
const termsVersion = "2026-10-25"

func termsOK(w http.ResponseWriter, r *http.Request) bool {
	if c, err := r.Cookie("vx_terms"); err == nil && c.Value == termsVersion {
		return true
	}
	if r.Method != "GET" {
		http.Error(w, "Accept the Terms of Service at /vortex/terms/ first.", 403)
		return false
	}
	http.Redirect(w, r, "/vortex/terms/?next="+url.QueryEscape(r.URL.RequestURI()), 303)
	return false
}

func qs(r *http.Request) string {
	if r.URL.RawQuery != "" {
		return "?" + r.URL.RawQuery
	}
	return ""
}

// ownerAlert tells the owner about a new Cloud PC request: an in-app
// notification via the gateway feed and, when SMTP is configured, an email.
func ownerAlert(user string) {
	title := "Cloud PC request from " + user
	body := user + " asked for Cloud PC access. Approve or deny it in Cloud PC (owner panel)."
	notifyLocal("owner", "cloudpc_request", title, body, pfx+"/")
	go sendMail(env("CPC_NOTIFY_EMAIL", "grimvirusoffical@gmail.com"), "[Red-XAI Vortex] "+title,
		body+"\n\nOpen: https://"+env("CPC_PUBLIC_HOST", "45.77.105.187")+pfx+"/\n")
}

func notifyLocal(to, kind, title, body, link string) {
	b, _ := json.Marshal(map[string]string{"to": to, "kind": kind, "title": title, "body": body, "link": link})
	c := &http.Client{Timeout: 5 * time.Second}
	resp, err := c.Post(env("CPC_NOTIFY", "http://127.0.0.1:18093/notify"), "application/json", bytes.NewReader(b))
	if err != nil {
		log.Printf("notify %s: %v", to, err)
		return
	}
	resp.Body.Close()
}

// sendMail uses CPC_SMTP_HOST, CPC_SMTP_PORT (587), CPC_SMTP_USER, CPC_SMTP_PASS,
// CPC_SMTP_FROM. Without a host it only logs.
func sendMail(to, subject, body string) {
	host := env("CPC_SMTP_HOST", "")
	if host == "" {
		log.Printf("email to owner skipped: CPC_SMTP_HOST not set (%s)", subject)
		return
	}
	port, user := env("CPC_SMTP_PORT", "587"), env("CPC_SMTP_USER", "")
	from := env("CPC_SMTP_FROM", user)
	msg := "From: Red-XAI Vortex <" + from + ">\r\nTo: " + to + "\r\nSubject: " + subject +
		"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + body
	var a smtp.Auth
	if user != "" {
		a = smtp.PlainAuth("", user, env("CPC_SMTP_PASS", ""), host)
	}
	if err := smtp.SendMail(host+":"+port, a, from, []string{to}, []byte(msg)); err != nil {
		log.Printf("email to owner failed: %v", err)
	}
}
