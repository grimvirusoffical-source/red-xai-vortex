package main

// External OpenAI-compatible providers. API keys are sealed with rsx ChaCha20-Poly1305
// under a server-only seal key; they are never returned by any endpoint.

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
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

const extPref = "ext-"

type ExtModel struct {
	ID     string `json:"id"`     // exposed id, ext-<slug>
	Name   string `json:"name"`   // custom display name
	Remote string `json:"remote"` // provider's model name
}

type Provider struct {
	ID      string     `json:"id"`
	Name    string     `json:"name"`
	BaseURL string     `json:"base_url"`
	Sealed  string     `json:"sealed_key"` // hex(nonce||ct||tag)
	Models  []ExtModel `json:"models"`
	Created int64      `json:"created"`
}

var (
	providers []*Provider
	sealKey   []byte
	slugRe    = regexp.MustCompile(`[^a-z0-9._-]+`)
)

func slug(s string) string {
	s = strings.Trim(slugRe.ReplaceAllString(strings.ToLower(s), "-"), "-")
	if len(s) > 48 {
		s = s[:48]
	}
	return s
}

func loadProviders() {
	k, err := os.ReadFile(filepath.Join(dir, "seal.key"))
	if errors.Is(err, os.ErrNotExist) {
		k, err = cbRandom(32)
		must(err)
		must(os.WriteFile(filepath.Join(dir, "seal.key"), k, 0600))
	} else {
		must(err)
	}
	sealKey = k
	if b, err := os.ReadFile(filepath.Join(dir, "providers.json")); err == nil {
		must(json.Unmarshal(b, &providers))
	}
}
func saveProviders() { writeJSON("providers.json", providers) }

func sealSecret(id, secret string) (string, error) {
	n, err := cbRandom(12)
	if err != nil {
		return "", err
	}
	ct, err := cbSeal(sealKey, n, []byte("redx-provider-key-v1:"+id), []byte(secret))
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(append(n, ct...)), nil
}

func openSecret(p *Provider) (string, error) {
	b, err := hex.DecodeString(p.Sealed)
	if err != nil || len(b) < 28 {
		return "", errors.New("bad sealed key")
	}
	pt, err := cbOpen(sealKey, b[:12], []byte("redx-provider-key-v1:"+p.ID), b[12:])
	return string(pt), err
}

// findExt returns the provider and remote model name for an exposed ext- id.
func findExt(model string) (*Provider, string) {
	if !strings.HasPrefix(model, extPref) {
		return nil, ""
	}
	mu.Lock()
	defer mu.Unlock()
	for _, p := range providers {
		for _, m := range p.Models {
			if m.ID == model {
				c := *p
				return &c, m.Remote
			}
		}
	}
	return nil, ""
}

func extReq(p *Provider, method, path string, body []byte) (*http.Response, error) {
	key, err := openSecret(p)
	if err != nil {
		return nil, errors.New("provider key unreadable")
	}
	u := strings.TrimRight(p.BaseURL, "/") + path
	req, _ := http.NewRequest(method, u, bytes.NewReader(body))
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	req.Header.Set("Content-Type", "application/json")
	return (&http.Client{Timeout: 10 * time.Minute}).Do(req)
}

// path is like /v1/chat/completions; providers' base URLs already include their version prefix.
func extPath(path string) string { return strings.TrimPrefix(path, "/v1") }

func extModelsList() []map[string]any {
	mu.Lock()
	defer mu.Unlock()
	var out []map[string]any
	for _, p := range providers {
		for _, m := range p.Models {
			out = append(out, map[string]any{"id": m.ID, "object": "model", "owned_by": "external:" + p.Name, "name": m.Name, "created": 0})
		}
	}
	return out
}

func validBase(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "https" || (u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost"))) && u.Host != ""
}

// admin handlers; returns true if handled
func providerAdmin(w http.ResponseWriter, r *http.Request, p string, in map[string]any) bool {
	str := func(f string) string { s, _ := in[f].(string); return strings.TrimSpace(s) }
	switch {
	case p == "/admin/providers" && r.Method == "GET":
		mu.Lock()
		var out []map[string]any
		for _, x := range providers {
			out = append(out, map[string]any{"id": x.ID, "name": x.Name, "base_url": x.BaseURL, "models": x.Models, "created": x.Created, "has_key": x.Sealed != ""})
		}
		mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"providers": out})
	case p == "/admin/providers" && r.Method == "POST":
		name, base := str("name"), strings.TrimRight(str("base_url"), "/")
		if name == "" || len(name) > 48 || !validBase(base) {
			errJSON(w, 400, "need a name and an https base URL")
			return true
		}
		id := str("id")
		if id == "" {
			id = slug(name)
		}
		var models []ExtModel
		if a, ok := in["models"].([]any); ok {
			for _, v := range a {
				m, _ := v.(map[string]any)
				rm, _ := m["remote"].(string)
				dn, _ := m["name"].(string)
				if strings.TrimSpace(rm) == "" {
					continue
				}
				if strings.TrimSpace(dn) == "" {
					dn = name + " " + rm
				}
				models = append(models, ExtModel{ID: extPref + slug(id+"-"+dn), Name: strings.TrimSpace(dn), Remote: strings.TrimSpace(rm)})
			}
		}
		mu.Lock()
		var cur *Provider
		for _, x := range providers {
			if x.ID == id {
				cur = x
			}
		}
		if cur == nil {
			cur = &Provider{ID: id, Created: time.Now().Unix()}
			providers = append(providers, cur)
		}
		cur.Name, cur.BaseURL, cur.Models = name, base, models
		if k := str("api_key"); k != "" {
			s, err := sealSecret(id, k)
			if err != nil {
				mu.Unlock()
				errJSON(w, 500, "seal failed")
				return true
			}
			cur.Sealed = s
		} else if cur.Sealed == "" {
			cur.Sealed, _ = sealSecret(id, "")
		}
		saveProviders()
		mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "id": id, "models": models})
	case strings.HasPrefix(p, "/admin/providers/") && strings.HasSuffix(p, "/test") && r.Method == "POST":
		id := strings.TrimSuffix(strings.TrimPrefix(p, "/admin/providers/"), "/test")
		var pr *Provider
		mu.Lock()
		for _, x := range providers {
			if x.ID == id {
				c := *x
				pr = &c
			}
		}
		mu.Unlock()
		if pr == nil {
			errJSON(w, 404, "no such provider")
			return true
		}
		res := map[string]any{"provider": id}
		t := time.Now()
		if resp, err := extReq(pr, "GET", "/models", nil); err != nil {
			res["models_error"] = err.Error()
		} else {
			var d struct{ Data []struct{ ID string } }
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
			resp.Body.Close()
			res["models_status"] = resp.StatusCode
			if json.Unmarshal(b, &d) == nil {
				var ids []string
				for _, m := range d.Data {
					ids = append(ids, m.ID)
				}
				res["remote_models"] = ids
			}
		}
		if len(pr.Models) > 0 {
			b, _ := json.Marshal(map[string]any{"model": pr.Models[0].Remote, "max_tokens": 8, "messages": []any{map[string]string{"role": "user", "content": "Reply with: ok"}}})
			if resp, err := extReq(pr, "POST", "/chat/completions", b); err != nil {
				res["chat_error"] = err.Error()
			} else {
				res["chat_status"] = resp.StatusCode
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
		}
		res["seconds"] = time.Since(t).Seconds()
		ok := res["models_status"] == 200 && (len(pr.Models) == 0 || res["chat_status"] == 200)
		res["ok"] = ok
		json.NewEncoder(w).Encode(res)
	case strings.HasPrefix(p, "/admin/providers/") && r.Method == "DELETE":
		id := strings.TrimPrefix(p, "/admin/providers/")
		mu.Lock()
		var keep []*Provider
		for _, x := range providers {
			if x.ID != id {
				keep = append(keep, x)
			}
		}
		found := len(keep) != len(providers)
		providers = keep
		saveProviders()
		mu.Unlock()
		if !found {
			errJSON(w, 404, "no such provider")
			return true
		}
		fmt.Fprint(w, `{"ok":true}`)
	default:
		return false
	}
	return true
}
