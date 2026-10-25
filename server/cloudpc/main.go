package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/smtp"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const pfx = "/vortex/cloudpc"

type sess struct {
	rxs     string
	user    string
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

// Cloud PC access: owners (CPC_OWNERS, comma-separated usernames; default jf) are auto-approved.
// Everyone else must Request access; an owner Approves from the panel.

type aclFile struct {
	Approved []string          `json:"approved"`
	Pending  map[string]string `json:"pending"` // username -> requested_at RFC3339
}

func aclPath() string { return env("CPC_ACL", "/var/lib/cloudpc/acl.json") }

func loadACL() aclFile {
	a := aclFile{Pending: map[string]string{}}
	b, err := os.ReadFile(aclPath())
	if err == nil {
		json.Unmarshal(b, &a)
		if a.Pending == nil {
			a.Pending = map[string]string{}
		}
	}
	return a
}

func saveACL(a aclFile) error {
	os.MkdirAll(filepath.Dir(aclPath()), 0750)
	b, _ := json.MarshalIndent(a, "", "  ")
	return os.WriteFile(aclPath(), b, 0640)
}

func owners() []string {
	v := env("CPC_OWNERS", "jf,maindirectory")
	var out []string
	for _, p := range strings.Split(v, ",") {
		p = strings.ToLower(strings.TrimSpace(p))
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func isOwner(username string) bool {
	u := strings.ToLower(strings.TrimSpace(username))
	for _, o := range owners() {
		if u == o {
			return true
		}
	}
	return false
}

func usernameOf(s *sess) string {
	parts := strings.SplitN(s.user, "\x00", 2)
	if len(parts) == 2 {
		return parts[1]
	}
	return s.user
}

func isApproved(username string) bool {
	if isOwner(username) {
		return true
	}
	a := loadACL()
	u := strings.ToLower(username)
	for _, x := range a.Approved {
		if strings.ToLower(x) == u {
			return true
		}
	}
	return false
}

func clientIP(r *http.Request) string {
	if v := r.Header.Get("CF-Connecting-IP"); v != "" {
		return v
	}
	h, _, _ := net.SplitHostPort(r.RemoteAddr)
	return h
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
	req, _ := http.NewRequest(method, acct+route, rd)
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
	json.NewDecoder(io.LimitReader(res.Body, 1<<16)).Decode(&m)
	return res.StatusCode, m
}

func str(m map[string]any, k string) string { v, _ := m[k].(string); return v }

func meOf(rxs string) (string, bool) {
	st, m := acctCall("me", "", rxs, nil)
	if st != 200 {
		return "", false
	}
	a, _ := m["account"].(map[string]any)
	if a == nil || str(a, "id") == "" {
		return "", false
	}
	return str(a, "id") + "\x00" + str(a, "username"), true
}

func getSess(r *http.Request) (string, *sess) {
	c, err := r.Cookie("cpc")
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
	if time.Since(s.checked) > 5*time.Minute {
		rxs := s.rxs
		mu.Unlock()
		_, ok := meOf(rxs)
		mu.Lock()
		if !ok {
			delete(sessions, c.Value)
			return "", nil
		}
		s.checked = time.Now()
	}
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
<input type="hidden" name="user" value="{{.}}"><span>{{.}}</span>
<button class="btn">Approve</button></form>
<form method="post" action="` + pfx + `/deny" style="display:inline-flex;gap:.5rem;align-items:center;margin:.4rem 0">
<input type="hidden" name="user" value="{{.}}">
<button class="btn ghost">Deny</button></form>
{{end}}{{else}}<p class="sub small">No pending requests.</p>{{end}}
</section>
<section class="card" style="margin-top:1rem"><h2>Approved users</h2>
{{if .ApprovedList}}{{range .ApprovedList}}
<form method="post" action="` + pfx + `/deny" style="display:flex;gap:.5rem;align-items:center;margin:.4rem 0">
<input type="hidden" name="user" value="{{.}}"><span>{{.}}</span>
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
		owner = isOwner(u)
		approved = isApproved(u)
		a := loadACL()
		_, pending = a.Pending[strings.ToLower(u)]
		if owner {
			for k := range a.Pending {
				pendingList = append(pendingList, k)
			}
			for _, x := range a.Approved {
				if !isOwner(x) {
					approvedList = append(approvedList, x)
				}
			}
		}
	}
	page.Execute(w, map[string]any{"Msg": msg, "User": u, "Owner": owner, "Approved": approved, "Pending": pending, "PendingList": pendingList, "ApprovedList": approvedList})
}

func sameOrigin(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" || o == "null" {
		return o == ""
	}
	u, err := url.Parse(o)
	return err == nil && u.Host == r.Host
}

func cloud(w http.ResponseWriter, r *http.Request) {
	p := strings.TrimPrefix(r.URL.Path, pfx)
	tok, s := getSess(r)
	if s != nil && !termsOK(w, r) {
		return
	}
	if strings.HasPrefix(p, "/desktop/") {
		if s == nil {
			toSignin(w, r)
			return
		}
		if s.port == "" {
			http.Redirect(w, r, pfx+"/", 303)
			return
		}
		mu.Lock()
		if time.Since(s.touched) > time.Minute {
			s.touched = time.Now()
			go run("cloudpc", "/usr/local/sbin/cloudpc-ctl", "touch", s.id)
		}
		port := s.port
		mu.Unlock()
		t, _ := url.Parse("http://127.0.0.1:" + port)
		rp := httputil.NewSingleHostReverseProxy(t)
		rp.FlushInterval = -1
		rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("desktop proxy: %v", err)
			http.Error(w, "desktop unreachable", 502)
		}
		r.URL.Path = strings.TrimPrefix(p, "/desktop")
		if r.URL.Path == "" {
			r.URL.Path = "/"
		}
		r.Header.Del("Cookie")
		r.Host = "127.0.0.1:" + port
		rp.ServeHTTP(w, r)
		return
	}
	if r.Method == "POST" && !sameOrigin(r) {
		http.Error(w, "bad origin", 403)
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
		u := usernameOf(s)
		if isApproved(u) {
			render(w, s, "You already have access.")
			return
		}
		a := loadACL()
		a.Pending[strings.ToLower(u)] = time.Now().UTC().Format(time.RFC3339)
		_ = saveACL(a)
		ownerAlert(u)
		render(w, s, "Access requested. The owner has been notified.")
	case "/approve":
		if !isOwner(usernameOf(s)) {
			http.Error(w, "forbidden", 403)
			return
		}
		u := strings.ToLower(strings.TrimSpace(r.FormValue("user")))
		if u == "" {
			render(w, s, "Missing user.")
			return
		}
		a := loadACL()
		delete(a.Pending, u)
		found := false
		for _, x := range a.Approved {
			if strings.ToLower(x) == u {
				found = true
				break
			}
		}
		if !found {
			a.Approved = append(a.Approved, u)
		}
		_ = saveACL(a)
		notifyLocal("user:"+u, "cloudpc_decision", "Cloud PC access approved", "You can now open your Cloud PC desktop.", pfx+"/")
		render(w, s, "Approved "+u+".")
	case "/deny":
		if !isOwner(usernameOf(s)) {
			http.Error(w, "forbidden", 403)
			return
		}
		u := strings.ToLower(strings.TrimSpace(r.FormValue("user")))
		if u == "" {
			render(w, s, "Missing user.")
			return
		}
		a := loadACL()
		delete(a.Pending, u)
		kept := a.Approved[:0]
		for _, x := range a.Approved {
			if strings.ToLower(x) != u {
				kept = append(kept, x)
			}
		}
		a.Approved = kept
		_ = saveACL(a)
		notifyLocal("user:"+u, "cloudpc_decision", "Cloud PC access denied", "An owner declined or revoked your Cloud PC access.", "")
		render(w, s, "Denied/revoked "+u+".")
	case "/start":
		if s == nil {
			http.Redirect(w, r, pfx+"/", 303)
			return
		}
		if !isApproved(usernameOf(s)) {
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

func sec(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		if !strings.HasPrefix(r.URL.Path, pfx+"/desktop/") {
			w.Header().Set("X-Frame-Options", "DENY")
		}
		h.ServeHTTP(w, r)
	})
}

func main() {
	m := http.NewServeMux()
	m.HandleFunc(pfx, cloud)
	m.HandleFunc(pfx+"/", cloud)
	fs := http.StripPrefix("/vortex/", http.FileServer(http.Dir(www)))
	m.HandleFunc("/vortex/signin", signin)
	m.HandleFunc("/vortex/signout", signout)
	m.HandleFunc("/vortex/", func(w http.ResponseWriter, r *http.Request) {
		// Public: stylesheet + desktop download artifacts (SHA256SUMS, installers).
		if r.TLS == nil && r.Header.Get("CF-Visitor") == "" {
			http.Redirect(w, r, "https://"+strings.Split(r.Host, ":")[0]+r.URL.RequestURI(), http.StatusMovedPermanently)
			return
		}
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
	m.HandleFunc("/v1/", func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil { // never accept API keys over cleartext
			http.Error(w, `{"error":{"code":426,"message":"use https"}}`, http.StatusUpgradeRequired)
			return
		}
		gwp.ServeHTTP(w, r)
	})
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

func secure(r *http.Request) bool { return r.TLS != nil || r.Header.Get("CF-Visitor") != "" }

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
		c, err := r.Cookie("cpcf")
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
		if st == 200 && str(m, "token") != "" {
			mu.Lock()
			delete(pending, c.Value)
			mu.Unlock()
			finish(w, r, str(m, "token"), p.next)
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
		if str(m, "token") != "" {
			finish(w, r, str(m, "token"), next)
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
	h := sum256([]byte("cloudpc-redx:" + strings.SplitN(who, "\x00", 2)[0]))
	b, err := randBytes(32)
	if err != nil {
		http.Error(w, "error", 500)
		return
	}
	t := hex.EncodeToString(b)
	mu.Lock()
	sessions[t] = &sess{rxs: rxs, user: who, checked: time.Now(), id: hex.EncodeToString(h[:8]), exp: time.Now().Add(12 * time.Hour)}
	mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "cpc", Value: t, Path: "/vortex", HttpOnly: true, Secure: secure(r), SameSite: http.SameSiteLaxMode, MaxAge: 43200})
	http.Redirect(w, r, next, 303)
}

func signout(w http.ResponseWriter, r *http.Request) {
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
