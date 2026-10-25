package main

// Minimal Vortex Plugin Store. Lists published plugins; upload requires a valid RedX session
// (X-RedX-Session or cookie rxs) verified against api.red-xai.com.

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
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
)

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
	Published   time.Time `json:"published"`
}

func main() {
	os.MkdirAll(dir, 0755)
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("/v1/plugins", plugins)
	mux.HandleFunc("/v1/plugins/", pluginOne)
	log.Println("plugin-store on", addr, "dir", dir)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func redxUser(r *http.Request) (string, bool) {
	tok := r.Header.Get("X-RedX-Session")
	if tok == "" {
		if c, err := r.Cookie("rxs"); err == nil {
			tok = c.Value
		}
	}
	if tok == "" {
		return "", false
	}
	req, _ := http.NewRequest("GET", acct+"me", nil)
	req.Header.Set("accept", "application/json")
	req.Header.Set("X-RedX-Session", tok)
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 200 {
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
	return u, u != ""
}

func plugins(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch r.Method {
	case "GET":
		var list []pluginMeta
		ents, _ := os.ReadDir(dir)
		for _, e := range ents {
			if !e.IsDir() {
				continue
			}
			b, err := os.ReadFile(filepath.Join(dir, e.Name(), "meta.json"))
			if err != nil {
				continue
			}
			var m pluginMeta
			if json.Unmarshal(b, &m) == nil {
				list = append(list, m)
			}
		}
		json.NewEncoder(w).Encode(map[string]any{"plugins": list})
	case "POST":
		user, ok := redxUser(r)
		if !ok {
			http.Error(w, `{"error":"sign in with RedX to upload"}`, 401)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, `{"error":"bad body"}`, 400)
			return
		}
		var raw map[string]any
		if json.Unmarshal(body, &raw) != nil {
			http.Error(w, `{"error":"invalid json"}`, 400)
			return
		}
		id, _ := raw["id"].(string)
		if !idRe.MatchString(id) {
			http.Error(w, `{"error":"bad id"}`, 400)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		d := filepath.Join(dir, id)
		os.MkdirAll(d, 0755)
		os.WriteFile(filepath.Join(d, "plugin.json"), body, 0644)
		meta := pluginMeta{
			ID: id, Name: str(raw, "name"), Version: str(raw, "version"),
			Description: str(raw, "description"), Author: str(raw, "author"),
			Uploader: user, Published: time.Now().UTC(),
		}
		if meta.Version == "" {
			meta.Version = "1.0.0"
		}
		mb, _ := json.MarshalIndent(meta, "", "  ")
		os.WriteFile(filepath.Join(d, "meta.json"), mb, 0644)
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "plugin": meta})
	default:
		http.Error(w, "method", 405)
	}
}

func pluginOne(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/v1/plugins/")
	id = strings.Trim(id, "/")
	if !idRe.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	b, err := os.ReadFile(filepath.Join(dir, id, "plugin.json"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

func str(m map[string]any, k string) string { v, _ := m[k].(string); return v }
