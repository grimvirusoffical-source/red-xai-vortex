package bridge

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Phone access: when "Phone chat on this network" is on, the full Vortex UI and bridge
// (everything the desktop can do) is served on the LAN, gated by a 6-digit PIN shown in
// Settings. A correct PIN gets an HttpOnly session cookie; 10 wrong PINs lock phone access
// until the app restarts. Chat from the phone follows the same Secure chat setting.

var phoneListen = envOr("VORTEX_PHONE_LISTEN", "0.0.0.0:18192")

var phone struct {
	sync.Mutex
	ln       net.Listener
	pin      string
	sessions map[string]time.Time
	fails    int
}

func randHex(n int) string { b := make([]byte, n); rand.Read(b); return hex.EncodeToString(b) }

func phoneInfo() (string, string) {
	phone.Lock()
	defer phone.Unlock()
	if phone.ln == nil {
		return "", ""
	}
	_, port, _ := net.SplitHostPort(phone.ln.Addr().String())
	return "http://" + lanIP() + ":" + port, phone.pin
}

// applyPhone starts or stops the LAN listener to match Settings.PhoneChat.
func (s *Server) applyPhone() {
    if !s.profileLive(){return}
	phone.Lock()
	defer phone.Unlock()
	if !s.St.Settings.PhoneChat {
		if phone.ln != nil {
			phone.ln.Close()
			phone.ln = nil
			os.Remove(phoneFile())
		}
		return
	}
	if phone.ln != nil {
		return
	}
	ln, err := net.Listen("tcp", phoneListen)
	if err != nil {
		fmt.Println("phone access:", err)
		return
	}
	n, _ := rand.Int(rand.Reader, big.NewInt(1000000))
	phone.pin = fmt.Sprintf("%06d", n.Int64())
	phone.sessions = map[string]time.Time{}
	phone.fails = 0
	phone.ln = ln
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	os.WriteFile(phoneFile(), []byte("http://"+lanIP()+":"+port+"\n"+phone.pin+"\n"), 0600) // read by the macOS app
	go http.Serve(ln, s.phoneGate(s.mux))
}

func (s *Server) phoneGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Frame-Options", "DENY")
		if r.URL.Path == "/phone/login" && r.Method == http.MethodPost {
			r.ParseForm()
			pin := strings.TrimSpace(r.FormValue("pin"))
			phone.Lock()
			locked := phone.fails >= 10
			ok := !locked && subtle.ConstantTimeCompare([]byte(pin), []byte(phone.pin)) == 1
			if ok {
				t := randHex(32)
				phone.sessions[t] = time.Now().Add(30 * 24 * time.Hour)
				phone.Unlock()
				http.SetCookie(w, &http.Cookie{Name: "vx_phone", Value: t, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 30 * 24 * 3600})
				http.Redirect(w, r, "/", http.StatusSeeOther)
				return
			}
			if !locked {
				phone.fails++
			}
			phone.Unlock()
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, loginPage(map[bool]string{true: "Too many wrong PINs. Restart Vortex on the PC.", false: "Wrong PIN."}[locked]))
			return
		}
		if c, err := r.Cookie("vx_phone"); err == nil {
			phone.Lock()
			exp, ok := phone.sessions[c.Value]
			phone.Unlock()
			if ok && time.Now().Before(exp) {
				// Block cross-site POSTs to the bridge from other pages.
				if r.Method == http.MethodPost {
					if o := r.Header.Get("Origin"); o != "" && !strings.HasSuffix(o, "://"+r.Host) {
						http.Error(w, "bad origin", http.StatusForbidden)
						return
					}
				}
				// The workspace bridge accepts a LAN host only after this gate has
				// authenticated its phone session. A request header cannot forge this.
				next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), workspacePhoneSessionKey{}, true)))
				return
			}
		}
		if strings.HasPrefix(r.URL.Path, "/bridge/") {
			http.Error(w, `{"error":"phone login required"}`, http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, loginPage(""))
	})
}

func loginPage(msg string) string {
	return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Red-XAI Vortex</title>
<style>body{background:#0b0b0d;color:#eee;font-family:system-ui;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
form{background:#16161a;border:1px solid #b00020;border-radius:14px;padding:24px;width:min(320px,90vw)}h1{color:#e0182d;font-size:20px;margin:0 0 12px}
input,button{width:100%;box-sizing:border-box;font-size:20px;padding:12px;border-radius:10px;border:1px solid #444;background:#0b0b0d;color:#eee;margin-top:10px}
button{background:#b00020;border:0;font-weight:600}p{color:#f66;min-height:1em}</style></head><body>
<form method="post" action="/phone/login"><h1>✕ Red-XAI Vortex</h1><div>Enter the PIN shown in Vortex Settings on your PC.</div>
<input name="pin" inputmode="numeric" autocomplete="one-time-code" maxlength="6" autofocus><button>Open Vortex</button><p>` + msg + `</p></form></body></html>`
}

func phoneFile() string { h, _ := os.UserHomeDir(); return filepath.Join(h, ".redx-link-phone") }
