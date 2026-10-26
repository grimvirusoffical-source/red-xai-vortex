package main

// Vortex Plugin Store. Public listing; upload/edit/unpublish require a valid RedX session
// (X-RedX-Session header) verified against api.red-xai.com. Plugins are owned by the RedX
// username that first published them; the author shown is that username.

import (
	"encoding/base64"
	"fmt"
	"hash/fnv"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	dir  = env("PLUGIN_STORE_DIR", "/var/lib/vortex-plugins")
	acct = env("REDX_ACCT", "https://api.red-xai.com/v1/accounts/")
	addr = env("PLUGIN_STORE_ADDR", "127.0.0.1:8095")
	idRe = regexp.MustCompile(`^[a-z0-9-]{2,40}$`)
	mu   sync.Mutex

	userCache = map[string]userHit{}
)

type userHit struct {
	user string
	at   time.Time
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

type pluginMeta struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Version     string    `json:"version"`
	Description string    `json:"description"`
	Author      string    `json:"author"`
	Uploader    string    `json:"uploader"`
	HasIcon     bool      `json:"hasIcon"`
	Icon        string    `json:"icon,omitempty"` // relative URL to the 256x256 PNG
	Installs    int       `json:"installs"`
	Published   time.Time `json:"published"`
	Updated     time.Time `json:"updated"`
}

func main() {
	os.MkdirAll(dir, 0755)
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("/v1/me", me)
	mux.HandleFunc("/v1/plugins", plugins)
	mux.HandleFunc("/v1/plugins/", pluginOne)
	log.Println("plugin-store on", addr, "dir", dir)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func jerr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"error": msg})
}

func redxUser(r *http.Request) (string, bool) {
	tok := r.Header.Get("X-RedX-Session")
	if tok == "" {
		return "", false
	}
	k := tok // in-memory cache only
	mu.Lock()
	if c, ok := userCache[k]; ok && time.Since(c.at) < 2*time.Minute {
		mu.Unlock()
		return c.user, true
	}
	mu.Unlock()
	req, _ := http.NewRequest("GET", acct+"me", nil)
	req.Header.Set("accept", "application/json")
	req.Header.Set("X-RedX-Session", tok)
	res, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil || res.StatusCode != 200 {
		if res != nil {
			res.Body.Close()
		}
		return "", false
	}
	defer res.Body.Close()
	var m map[string]any
	json.NewDecoder(io.LimitReader(res.Body, 1<<16)).Decode(&m)
	a, _ := m["account"].(map[string]any)
	if a == nil {
		return "", false
	}
	u, _ := a["username"].(string)
	if u == "" {
		u, _ = a["id"].(string)
	}
	if u == "" {
		return "", false
	}
	mu.Lock()
	userCache[k] = userHit{u, time.Now()}
	mu.Unlock()
	return u, true
}

func readMeta(id string) (pluginMeta, bool) {
	var m pluginMeta
	b, err := os.ReadFile(filepath.Join(dir, id, "meta.json"))
	if err != nil || json.Unmarshal(b, &m) != nil {
		return m, false
	}
	if m.Author == "" {
		m.Author = m.Uploader
	}
	if m.HasIcon {
		m.Icon = "v1/plugins/" + m.ID + "/icon.png"
	}
	return m, true
}

func writeMeta(m pluginMeta) {
	m.Icon = ""
	mb, _ := json.MarshalIndent(m, "", "  ")
	os.WriteFile(filepath.Join(dir, m.ID, "meta.json"), mb, 0644)
}

func listAll() []pluginMeta {
	list := []pluginMeta{}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		if e.IsDir() {
			if m, ok := readMeta(e.Name()); ok {
				list = append(list, m)
			}
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Updated.After(list[j].Updated) })
	return list
}

func me(w http.ResponseWriter, r *http.Request) {
	u, ok := redxUser(r)
	if !ok {
		jerr(w, 401, "You must sign in to Red-XAI first to upload.")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"username": u})
}

// decodeIcon accepts a data:image/png;base64 URL (the apps fit icons to 256x256 PNG).
func decodeIcon(s string) ([]byte, bool) {
	const p = "data:image/png;base64,"
	if !strings.HasPrefix(s, p) {
		return nil, false
	}
	b, err := base64.StdEncoding.DecodeString(s[len(p):])
	if err != nil || len(b) > 512<<10 || len(b) < 8 || string(b[1:4]) != "PNG" {
		return nil, false
	}
	return b, true
}

// save validates the plugin JSON, strips the inline icon to icon.png, and writes plugin.json.
func save(user string, raw map[string]any, existing *pluginMeta) (pluginMeta, int, string) {
	id, _ := raw["id"].(string)
	if !idRe.MatchString(id) {
		return pluginMeta{}, 400, "bad id (use 2-40 of a-z 0-9 -)"
	}
	d := filepath.Join(dir, id)
	now := time.Now().UTC()
	m := pluginMeta{ID: id, Uploader: user, Author: user, Published: now}
	if existing != nil {
		m = *existing
	}
	m.Name, m.Version, m.Description = str(raw, "name"), str(raw, "version"), str(raw, "description")
	if m.Name == "" {
		m.Name = id
	}
	if m.Version == "" {
		m.Version = "1.0.0"
	}
	m.Author, m.Updated = user, now
	os.MkdirAll(d, 0755)
	if ic, _ := raw["icon"].(string); ic != "" {
		if b, ok := decodeIcon(ic); ok {
			os.WriteFile(filepath.Join(d, "icon.png"), b, 0644)
			m.HasIcon = true
		}
	}
	raw["author"] = user
	delete(raw, "icon")
	body, _ := json.MarshalIndent(raw, "", "  ")
	os.WriteFile(filepath.Join(d, "plugin.json"), body, 0644)
	writeMeta(m)
	m, _ = readMeta(id)
	return m, 200, ""
}

func plugins(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch r.Method {
	case "GET":
		list := listAll()
		if r.URL.Query().Get("mine") == "1" {
			u, ok := redxUser(r)
			if !ok {
				jerr(w, 401, "You must sign in to Red-XAI first.")
				return
			}
			mine := []pluginMeta{}
			for _, m := range list {
				if strings.EqualFold(m.Uploader, u) {
					mine = append(mine, m)
				}
			}
			json.NewEncoder(w).Encode(map[string]any{"plugins": mine, "username": u})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"plugins": list})
	case "POST":
		user, ok := redxUser(r)
		if !ok {
			jerr(w, 401, "You must sign in to Red-XAI first to upload.")
			return
		}
		var raw map[string]any
		if json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&raw) != nil {
			jerr(w, 400, "invalid json")
			return
		}
		id, _ := raw["id"].(string)
		mu.Lock()
		defer mu.Unlock()
		var ex *pluginMeta
		if m, ok := readMeta(id); ok {
			if !strings.EqualFold(m.Uploader, user) {
				jerr(w, 409, "That plugin id belongs to another author; pick a different id.")
				return
			}
			ex = &m
		}
		m, code, msg := save(user, raw, ex)
		if code != 200 {
			jerr(w, code, msg)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "plugin": m})
	default:
		jerr(w, 405, "method")
	}
}

func pluginOne(w http.ResponseWriter, r *http.Request) {
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/v1/plugins/"), "/")
	parts := strings.SplitN(rest, "/", 2)
	id := parts[0]
	sub := ""
	if len(parts) == 2 {
		sub = parts[1]
	}
	if !idRe.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	d := filepath.Join(dir, id)
	switch {
	case sub == "icon.png" && r.Method == "GET":
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=300")
		http.ServeFile(w, r, filepath.Join(d, "icon.png"))
	case sub == "install" && r.Method == "POST":
		// Count an install once per client (RedX user, else hashed IP) per plugin.
		who := r.Header.Get("X-Forwarded-For")
		if u, ok := redxUser(r); ok {
			who = "u:" + strings.ToLower(u)
		}
		h := fnv.New64a()
		h.Write([]byte(id + "|" + who))
		mark := filepath.Join(d, "installs", fmt.Sprintf("%016x", h.Sum64()))
		mu.Lock()
		m, ok := readMeta(id)
		if !ok {
			mu.Unlock()
			http.NotFound(w, r)
			return
		}
		if _, err := os.Stat(mark); err != nil {
			os.MkdirAll(filepath.Dir(mark), 0755)
			os.WriteFile(mark, nil, 0644)
			m.Installs++
			writeMeta(m)
		}
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "installs": m.Installs})
	case sub == "" && r.Method == "GET":
		b, err := os.ReadFile(filepath.Join(d, "plugin.json"))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		var raw map[string]any
		json.Unmarshal(b, &raw)
		if m, ok := readMeta(id); ok && m.HasIcon {
			if ib, err := os.ReadFile(filepath.Join(d, "icon.png")); err == nil {
				raw["icon"] = "data:image/png;base64," + base64.StdEncoding.EncodeToString(ib)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(raw)
	case sub == "" && (r.Method == "PUT" || r.Method == "DELETE"):
		user, ok := redxUser(r)
		if !ok {
			jerr(w, 401, "You must sign in to Red-XAI first.")
			return
		}
		mu.Lock()
		defer mu.Unlock()
		m, ok := readMeta(id)
		if !ok {
			jerr(w, 404, "not found")
			return
		}
		if !strings.EqualFold(m.Uploader, user) {
			jerr(w, 403, "Only the author can change this plugin.")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "DELETE" {
			os.RemoveAll(d)
			json.NewEncoder(w).Encode(map[string]any{"ok": true, "deleted": id})
			return
		}
		var patch map[string]any
		if json.NewDecoder(io.LimitReader(r.Body, 2<<20)).Decode(&patch) != nil {
			jerr(w, 400, "invalid json")
			return
		}
		var raw map[string]any
		b, _ := os.ReadFile(filepath.Join(d, "plugin.json"))
		json.Unmarshal(b, &raw)
		if raw == nil {
			raw = map[string]any{}
		}
		for k, v := range patch {
			if k != "id" && k != "author" {
				raw[k] = v
			}
		}
		raw["id"] = id
		nm, code, msg := save(user, raw, &m)
		if code != 200 {
			jerr(w, code, msg)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "plugin": nm})
	default:
		jerr(w, 405, "method")
	}
}

func str(m map[string]any, k string) string { v, _ := m[k].(string); return strings.TrimSpace(v) }
