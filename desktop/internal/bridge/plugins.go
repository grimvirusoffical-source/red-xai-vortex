package bridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

)

// Plugin store client. The store runs on the Vortex (Vultr) server behind https://<host>/plugins/.
// Uploads, edits and unpublishing are tied to the signed-in RedX username.

var pluginIDRe = regexp.MustCompile(`^[a-z0-9-]{2,40}$`)

func (s *Server) storeBase() string {
	if v := os.Getenv("VORTEX_PLUGIN_STORE"); v != "" {
		return strings.TrimRight(v, "/")
	}
	u, err := url.Parse(s.St.Settings.BaseURL)
	if err != nil || u.Host == "" {
		return "https://45.77.105.187/plugins/v1/plugins"
	}
	return u.Scheme + "://" + u.Host + "/plugins/v1/plugins"
}

func (s *Server) pluginReq(method, suffix string, body any, auth bool) map[string]any {
	if strings.HasPrefix(suffix, "/") && !pluginIDRe.MatchString(strings.SplitN(strings.TrimPrefix(suffix, "/"), "/", 2)[0]) {
		return map[string]any{"ok": false, "message": "bad plugin id"}
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, s.storeBase()+suffix, rd)
	req.Header.Set("Content-Type", "application/json")
	if auth {
		tok := s.secretGet("redx-session")
		if tok == "" {
			return map[string]any{"ok": false, "needSignIn": true, "message": "You must sign in to Red-XAI first to upload."}
		}
		req.Header.Set("X-RedX-Session", tok)
	}
	res, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return map[string]any{"ok": false, "message": "Plugin store unreachable: " + err.Error()}
	}
	defer res.Body.Close()
	out := map[string]any{}
	json.NewDecoder(io.LimitReader(res.Body, 8<<20)).Decode(&out)
	if res.StatusCode == 401 {
		return map[string]any{"ok": false, "needSignIn": true, "message": "You must sign in to Red-XAI first to upload."}
	}
	if res.StatusCode >= 300 {
		msg, _ := out["error"].(string)
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", res.StatusCode)
		}
		return map[string]any{"ok": false, "message": msg}
	}
	if _, ok := out["ok"]; !ok {
		out["ok"] = true
	}
	out["storeBase"] = strings.TrimSuffix(s.storeBase(), "/v1/plugins")
	return out
}

// pluginMake asks vortex-mini for a plugin manifest; falls back to a scaffold if the model is unreachable.
func (s *Server) pluginMake(desc string) map[string]any {
	desc = strings.TrimSpace(desc)
	if desc == "" {
		return map[string]any{"error": "Describe the plugin first."}
	}
	id := slug(desc)
	doc := map[string]any{"id": id, "name": titleOf(desc), "version": "1.0.0", "description": desc,
		"tools": []map[string]any{{"name": "run", "description": desc, "kind": "prompt", "prompt": desc + "\n\nInput: {{input}}"}}}
	sys := "You write Red-XAI Vortex plugin manifests. Reply with ONLY one JSON object, no prose, no code fence. Schema: " +
		`{"id":"lowercase-dashes","name":"Title","version":"1.0.0","description":"...","tools":[{"name":"snake_case","description":"...","kind":"prompt|http","prompt":"template with {{input}} (kind prompt)","url":"https://... (kind http)","method":"GET|POST"}]}` +
		". Use 1-4 tools. Prefer kind prompt unless a public HTTPS API is clearly needed."
	if txt, err := s.complete("", "vortex-mini", []map[string]string{{"role": "system", "content": sys}, {"role": "user", "content": desc}}, 700); err == nil {
		if i, j := strings.Index(txt, "{"), strings.LastIndex(txt, "}"); i >= 0 && j > i {
			var m map[string]any
			if json.Unmarshal([]byte(txt[i:j+1]), &m) == nil {
				if t, ok := m["tools"].([]any); ok && len(t) > 0 {
					if v, _ := m["id"].(string); !pluginIDRe.MatchString(v) {
						m["id"] = id
					}
					if v, _ := m["version"].(string); v == "" {
						m["version"] = "1.0.0"
					}
					doc = m
				}
			}
		}
	}
	delete(doc, "author") // the store sets the author to your RedX username
	b, _ := json.MarshalIndent(doc, "", "  ")
	return map[string]any{"json": string(b)}
}

func slug(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	dash := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			dash = false
		} else if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
		if b.Len() >= 32 {
			break
		}
	}
	out := strings.Trim(b.String(), "-")
	if len(out) < 2 {
		out = fmt.Sprintf("plugin-%d", time.Now().Unix()%100000)
	}
	return out
}

func titleOf(s string) string {
	w := strings.Fields(s)
	if len(w) > 5 {
		w = w[:5]
	}
	for i := range w {
		w[i] = strings.ToUpper(w[i][:1]) + w[i][1:]
	}
	return strings.Join(w, " ")
}

func (s *Server) pluginUpload(raw string) map[string]any {
	var doc map[string]any
	if json.Unmarshal([]byte(raw), &doc) != nil {
		return map[string]any{"ok": false, "message": "Generate a plugin first (the JSON is not valid)."}
	}
	return s.pluginReq("POST", "", doc, true)
}

func (s *Server) pluginStore() map[string]any { return s.pluginReq("GET", "", nil, false) }

func (s *Server) pluginsDir() string { return filepath.Join(s.St.Dir, "plugins") }

// pluginInstall downloads a plugin manifest into <config>/plugins/<id>.json and bumps its install count.
func (s *Server) pluginInstall(id string) map[string]any {
	if !pluginIDRe.MatchString(id) {
		return map[string]any{"ok": false, "message": "bad plugin id"}
	}
	res, err := (&http.Client{Timeout: 30 * time.Second}).Get(s.storeBase() + "/" + id)
	if err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if res.StatusCode != 200 || !json.Valid(b) {
		return map[string]any{"ok": false, "message": fmt.Sprintf("download failed (HTTP %d)", res.StatusCode)}
	}
	os.MkdirAll(s.pluginsDir(), 0700)
	if err := os.WriteFile(filepath.Join(s.pluginsDir(), id+".json"), b, 0600); err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	c := s.pluginReq("POST", "/"+id+"/install", map[string]any{}, s.secretGet("redx-session") != "")
	return map[string]any{"ok": true, "message": "Installed " + id, "installs": c["installs"]}
}

func (s *Server) pluginInstalled() map[string]any {
	ents, _ := os.ReadDir(s.pluginsDir())
	ids := []string{}
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".json") {
			ids = append(ids, strings.TrimSuffix(e.Name(), ".json"))
		}
	}
	return map[string]any{"ok": true, "ids": ids}
}

// pluginIcon asks the Vortex gateway for a square icon (OpenAI images API). The UI fits it to 256x256.
func (s *Server) pluginIcon(prompt string) map[string]any {
	if prompt == "" {
		prompt = "plugin"
	}
	base := s.St.Settings.BaseURL
	key := s.secretGet("vortex-api-key")
	body, _ := json.Marshal(map[string]any{"model": "vortex-image", "prompt": "flat app icon, centered, dark background, red accent: " + prompt, "size": "256x256", "n": 1, "response_format": "b64_json"})
	req, _ := http.NewRequest("POST", base+"/images/generations", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	res, err := (&http.Client{Timeout: 180 * time.Second}).Do(req)
	if err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	defer res.Body.Close()
	var out struct {
		Data []struct {
			B64 string `json:"b64_json"`
			URL string `json:"url"`
		} `json:"data"`
	}
	b, _ := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	json.Unmarshal(b, &out)
	if len(out.Data) == 0 || (out.Data[0].B64 == "" && out.Data[0].URL == "") {
		return map[string]any{"ok": false, "message": fmt.Sprintf("image generation failed (HTTP %d)", res.StatusCode)}
	}
	if out.Data[0].B64 != "" {
		return map[string]any{"ok": true, "dataURL": "data:image/png;base64," + out.Data[0].B64}
	}
	return map[string]any{"ok": true, "dataURL": out.Data[0].URL}
}
