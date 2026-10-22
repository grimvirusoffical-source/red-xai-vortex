package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Owner panel lock + device/IP ban list.
// Password is Argon2id (rsx) PHC, stored at <dir>/owner.phc — never the plaintext.
// Attempts are counted server-side by device ID so reinstalling the app does not reset them.

const ownerMaxFails = 3

type ownerAttempt struct {
	Count    int      `json:"count"`
	Last     int64    `json:"last"`
	IPs      []string `json:"ips,omitempty"`
	BannedAt int64    `json:"banned_at,omitempty"`
}

type banFile struct {
	IPs      []string                  `json:"ips"`
	Devices  []string                  `json:"devices"`
	Attempts map[string]*ownerAttempt  `json:"attempts"`
}

var (
	ownerMu   sync.Mutex
	ownerPHC  string
	bans      = banFile{Attempts: map[string]*ownerAttempt{}}
	ownerToks = map[string]int64{} // device -> expiry unix
)

func ownerPaths() (phc, ban string) {
	return filepath.Join(dir, "owner.phc"), filepath.Join(dir, "bans.json")
}

func loadOwner() {
	phcPath, banPath := ownerPaths()
	if b, err := os.ReadFile(phcPath); err == nil {
		ownerPHC = strings.TrimSpace(string(b))
	}
	if b, err := os.ReadFile(banPath); err == nil {
		var f banFile
		if json.Unmarshal(b, &f) == nil {
			if f.Attempts == nil {
				f.Attempts = map[string]*ownerAttempt{}
			}
			bans = f
		}
	}
}

func saveBans() {
	_, banPath := ownerPaths()
	writeJSON(filepath.Base(banPath), bans)
}

func setOwnerPassword(pw string) error {
	h, err := cbHashPasswordPHC([]byte(pw))
	if err != nil {
		return err
	}
	phcPath, _ := ownerPaths()
	if err := os.WriteFile(phcPath, []byte(h+"\n"), 0600); err != nil {
		return err
	}
	ownerMu.Lock()
	ownerPHC = h
	ownerMu.Unlock()
	return nil
}

func clientIP(r *http.Request) string {
	if x := strings.TrimSpace(r.Header.Get("CF-Connecting-IP")); x != "" {
		return x
	}
	if x := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); x != "" {
		return strings.TrimSpace(strings.Split(x, ",")[0])
	}
	if x := strings.TrimSpace(r.Header.Get("X-Vortex-Client-IP")); x != "" {
		return x
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func deviceFrom(r *http.Request) string {
	d := strings.TrimSpace(r.Header.Get("X-Vortex-Device"))
	if d == "" {
		d = strings.TrimSpace(r.URL.Query().Get("device"))
	}
	// accept 64-char hex (sha256) only
	if len(d) != 64 {
		return ""
	}
	for _, c := range d {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return ""
		}
	}
	return strings.ToLower(d)
}

// hashDeviceUUID returns the rsx SHA-256 hex of a raw hardware UUID string.
func hashDeviceUUID(uuid string) string {
	h := cbSHA256([]byte(strings.TrimSpace(uuid)))
	return hex.EncodeToString(h[:])
}

func isBanned(ip, device string) bool {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	if ip != "" && ip != "127.0.0.1" && ip != "::1" {
		for _, x := range bans.IPs {
			if x == ip {
				return true
			}
		}
	}
	if device != "" {
		for _, x := range bans.Devices {
			if x == device {
				return true
			}
		}
	}
	return false
}

func refuseIfBanned(w http.ResponseWriter, r *http.Request) bool {
	ip, dev := clientIP(r), deviceFrom(r)
	if isBanned(ip, dev) {
		errJSON(w, 403, "device or IP banned")
		return true
	}
	return false
}

func addUnique(ss *[]string, v string) {
	if v == "" {
		return
	}
	for _, x := range *ss {
		if x == v {
			return
		}
	}
	*ss = append(*ss, v)
}

func banDevice(device, ip string) {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	addUnique(&bans.Devices, device)
	if ip != "" && ip != "127.0.0.1" && ip != "::1" {
		addUnique(&bans.IPs, ip)
	}
	a := bans.Attempts[device]
	if a == nil {
		a = &ownerAttempt{}
		bans.Attempts[device] = a
	}
	a.BannedAt = time.Now().Unix()
	addUnique(&a.IPs, ip)
	saveBans()
}

func recordFail(device, ip string) (remaining int, banned bool) {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	if device == "" {
		device = "unknown"
	}
	a := bans.Attempts[device]
	if a == nil {
		a = &ownerAttempt{}
		bans.Attempts[device] = a
	}
	a.Count++
	a.Last = time.Now().Unix()
	addUnique(&a.IPs, ip)
	if a.Count >= ownerMaxFails {
		addUnique(&bans.Devices, device)
		if ip != "" && ip != "127.0.0.1" && ip != "::1" {
			addUnique(&bans.IPs, ip)
		}
		a.BannedAt = a.Last
		saveBans()
		return 0, true
	}
	saveBans()
	return ownerMaxFails - a.Count, false
}

func clearBans() {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	bans = banFile{IPs: nil, Devices: nil, Attempts: map[string]*ownerAttempt{}}
	saveBans()
}

func listBans() banFile {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	// shallow copy for printing
	out := banFile{IPs: append([]string{}, bans.IPs...), Devices: append([]string{}, bans.Devices...), Attempts: map[string]*ownerAttempt{}}
	for k, v := range bans.Attempts {
		c := *v
		out.Attempts[k] = &c
	}
	return out
}

func ownerUnlocked(device string) bool {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	exp, ok := ownerToks[device]
	return ok && exp > time.Now().Unix()
}

func grantOwner(device string) {
	ownerMu.Lock()
	defer ownerMu.Unlock()
	ownerToks[device] = time.Now().Add(12 * time.Hour).Unix()
	// successful unlock resets attempt counter for this device (not a ban clear)
	if a := bans.Attempts[device]; a != nil && a.BannedAt == 0 {
		a.Count = 0
		saveBans()
	}
}

// handleOwnerAdmin serves /admin/owner/* (admin key already checked).
func handleOwnerAdmin(w http.ResponseWriter, r *http.Request, p string) bool {
	switch {
	case p == "/admin/owner/status" && r.Method == "GET":
		ownerMu.Lock()
		has := ownerPHC != ""
		ownerMu.Unlock()
		dev := deviceFrom(r)
		json.NewEncoder(w).Encode(map[string]any{
			"configured": has,
			"unlocked":   has && ownerUnlocked(dev),
			"device":     dev,
			"banned":     isBanned(clientIP(r), dev),
		})
		return true
	case p == "/admin/owner/unlock" && r.Method == "POST":
		var body struct {
			Password string `json:"password"`
			Device   string `json:"device_id"`
			ClientIP string `json:"client_ip"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			errJSON(w, 400, "bad json")
			return true
		}
		dev := strings.ToLower(strings.TrimSpace(body.Device))
		if len(dev) != 64 {
			errJSON(w, 400, "device_id required (64-char hex)")
			return true
		}
		ip := strings.TrimSpace(body.ClientIP)
		if ip == "" {
			ip = clientIP(r)
		}
		if isBanned(ip, dev) {
			w.WriteHeader(403)
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "banned": true, "wipe": true})
			return true
		}
		ownerMu.Lock()
		phc := ownerPHC
		ownerMu.Unlock()
		if phc == "" {
			errJSON(w, 503, "owner password not configured")
			return true
		}
		ok, err := cbVerifyPasswordPHC([]byte(body.Password), phc)
		if err != nil {
			errJSON(w, 500, "verify failed")
			return true
		}
		if !ok {
			rem, banned := recordFail(dev, ip)
			if banned {
				w.WriteHeader(403)
				json.NewEncoder(w).Encode(map[string]any{"ok": false, "banned": true, "wipe": true, "remaining": 0})
				return true
			}
			w.WriteHeader(401)
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "banned": false, "remaining": rem})
			return true
		}
		grantOwner(dev)
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "unlocked": true})
		return true
	case p == "/admin/owner/lock" && r.Method == "POST":
		dev := deviceFrom(r)
		ownerMu.Lock()
		delete(ownerToks, dev)
		ownerMu.Unlock()
		w.Write([]byte(`{"ok":true}`))
		return true
	case p == "/admin/owner/bans" && r.Method == "GET":
		json.NewEncoder(w).Encode(listBans())
		return true
	case p == "/admin/owner/bans/clear" && r.Method == "POST":
		clearBans()
		w.Write([]byte(`{"ok":true}`))
		return true
	}
	return false
}

// requireOwner gates sensitive admin routes when an owner password is configured.
func requireOwner(w http.ResponseWriter, r *http.Request) bool {
	ownerMu.Lock()
	has := ownerPHC != ""
	ownerMu.Unlock()
	if !has {
		return true // not configured → open (first-run / stdcrypto)
	}
	dev := deviceFrom(r)
	if ownerUnlocked(dev) {
		return true
	}
	errJSON(w, 401, "owner unlock required")
	return false
}

func runVortexBanCLI(args []string) int {
	load()
	loadOwner()
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: vortex-ban list|clear")
		return 2
	}
	switch args[0] {
	case "list":
		b, _ := json.MarshalIndent(listBans(), "", "  ")
		fmt.Println(string(b))
		return 0
	case "clear":
		clearBans()
		fmt.Println("bans cleared")
		return 0
	default:
		fmt.Fprintln(os.Stderr, "usage: vortex-ban list|clear")
		return 2
	}
}
