// vortex-base is an owner-managed, read-only knowledge source server.
// Importing, deleting and granting access happen locally, never over its HTTP API.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const maxSourceBytes int64 = 128 << 20
const maxTextBytes = 1 << 20
const maxManifestText = 1 << 20
const maxCatalogBytes = 32 << 20

type Source struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	MIMEType  string `json:"mimeType"`
	Text      string `json:"text,omitempty"`
	URL       string `json:"url,omitempty"`
	Bytes     int64  `json:"bytes"`
	UpdatedAt string `json:"updatedAt"`
	SHA256    string `json:"sha256,omitempty"`
	// ObjectID is private catalog storage metadata. It is omitted from HTTP
	// responses so local publishing details do not become client context.
	ObjectID string `json:"objectID,omitempty"`
}

type Grant struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Hash      string   `json:"hash"`
	Scopes    []string `json:"scopes"`
	ExpiresAt string   `json:"expiresAt,omitempty"`
}

type Catalog struct {
	Version    int      `json:"version"`
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Revision   int      `json:"revision"`
	QuotaBytes int64    `json:"quotaBytes"`
	Sources    []Source `json:"sources"`
	Grants     []Grant  `json:"grants"`
}

type Host struct {
	dir string
	mu  sync.Mutex
}

func uid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func validID(id string) bool { b, e := hex.DecodeString(id); return e == nil && len(b) == 16 }
func (h *Host) load() (Catalog, error) {
	var c Catalog
	b, e := os.ReadFile(filepath.Join(h.dir, "catalog.json"))
	if e != nil {
		return c, e
	}
	if len(b) > maxCatalogBytes {
		return c, errors.New("catalog too large")
	}
	e = json.Unmarshal(b, &c)
	if e == nil && (c.Version != 1 || !validID(c.ID) || c.QuotaBytes < 1) {
		e = errors.New("invalid catalog version or identity")
	}
	return c, e
}
func (h *Host) save(c Catalog) error {
	b, e := json.MarshalIndent(c, "", "  ")
	if e != nil {
		return e
	}
	if len(b) > maxCatalogBytes {
		return errors.New("Base metadata/text index exceeds 32 MiB; split this collection into smaller Bases")
	}
	f, e := os.CreateTemp(h.dir, ".catalog-*")
	if e != nil {
		return e
	}
	p := f.Name()
	defer os.Remove(p)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(b)
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	return os.Rename(p, filepath.Join(h.dir, "catalog.json"))
}
func (h *Host) init(name string, quota int64) error {
	if strings.TrimSpace(name) == "" || quota < 1 {
		return errors.New("name and positive quota required")
	}
	if _, e := os.Stat(filepath.Join(h.dir, "catalog.json")); e == nil {
		return errors.New("Base already exists; existing catalog preserved")
	}
	if e := os.MkdirAll(filepath.Join(h.dir, "objects"), 0700); e != nil {
		return e
	}
	return h.save(Catalog{Version: 1, ID: uid(), Name: strings.TrimSpace(name), Revision: 1, QuotaBytes: quota, Sources: []Source{}, Grants: []Grant{}})
}
func sourceKind(mt string) string {
	for _, k := range []string{"image", "audio", "video"} {
		if strings.HasPrefix(mt, k+"/") {
			return k
		}
	}
	if strings.HasPrefix(mt, "text/") || mt == "application/json" {
		return "text"
	}
	return "document"
}
func (h *Host) add(path, name, sourceURL, description string) (Source, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c, e := h.load()
	if e != nil {
		return Source{}, e
	}
	if len(c.Sources) >= 1000 {
		return Source{}, errors.New("maximum 1000 sources per Base")
	}
	s := Source{ID: uid(), Name: strings.TrimSpace(name), URL: sourceURL, Text: description, UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
	if s.URL != "" {
		u, e := url.Parse(s.URL)
		if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return s, errors.New("source URL must be HTTPS without credentials, query tokens or fragments")
		}
	}
	if len(description) > maxTextBytes {
		return s, errors.New("description/transcript exceeds 1 MiB")
	}
	var dest string
	if path != "" {
		f, e := os.Open(path)
		if e != nil {
			return s, e
		}
		defer f.Close()
		st, e := f.Stat()
		if e != nil {
			return s, e
		}
		if !st.Mode().IsRegular() || st.Size() > maxSourceBytes {
			return s, errors.New("source must be a regular file up to 128 MiB")
		}
		if s.Name == "" {
			s.Name = filepath.Base(path)
		}
		mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
		if mt == "" {
			mt = "application/octet-stream"
		}
		s.MIMEType = mt
		s.Kind = sourceKind(mt)
		used := int64(0)
		for _, v := range c.Sources {
			used += v.Bytes
		}
		if st.Size()+int64(len(description))+used > c.QuotaBytes {
			return s, errors.New("Base storage quota exceeded")
		}
		dest = filepath.Join(h.dir, "objects", s.ID)
		o, e := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return s, e
		}
		hash := sha256.New()
		n, e := io.Copy(io.MultiWriter(o, hash), io.LimitReader(f, maxSourceBytes+1))
		ce := o.Close()
		if e == nil {
			e = ce
		}
		if e != nil || n > maxSourceBytes {
			os.Remove(dest)
			return s, errors.New("source copy failed or exceeded size limit")
		}
		s.Bytes = n + int64(len(description))
		s.SHA256 = hex.EncodeToString(hash.Sum(nil))
		if s.Kind == "text" && n <= maxTextBytes {
			if b, e := os.ReadFile(dest); e == nil && utf8.Valid(b) {
				s.Text = string(b) + "\n" + description
			}
		}
	} else {
		if s.Name == "" {
			s.Name = "Document reference"
		}
		s.Kind = "document"
		s.MIMEType = "text/plain"
		s.Bytes = int64(len(description))
		if s.URL == "" && s.Text == "" {
			return s, errors.New("file, document URL or text is required")
		}
	}
	used := int64(0)
	for _, v := range c.Sources {
		used += v.Bytes
	}
	if used+s.Bytes > c.QuotaBytes {
		if dest != "" {
			os.Remove(dest)
		}
		return s, errors.New("Base storage quota exceeded")
	}
	c.Sources = append(c.Sources, s)
	c.Revision++
	if e = h.save(c); e != nil {
		if dest != "" {
			os.Remove(dest)
		}
		return s, e
	}
	return s, nil
}
func (h *Host) grant(name, out, scopes string, days int) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c, e := h.load()
	if e != nil {
		return "", e
	}
	ss := strings.Split(scopes, ",")
	for _, s := range ss {
		if s != "read" && s != "search" {
			return "", errors.New("scopes must be read and/or search")
		}
	}
	if days < 1 || days > 365 {
		return "", errors.New("expiry must be between 1 and 365 days")
	}
	if out == "" {
		return "", errors.New("-out is required; credentials are never printed")
	}
	token := uid() + uid()
	hash := sha256.Sum256([]byte(token))
	g := Grant{ID: uid(), Name: name, Hash: hex.EncodeToString(hash[:]), Scopes: ss, ExpiresAt: time.Now().UTC().Add(time.Duration(days) * 24 * time.Hour).Format(time.RFC3339)}
	f, e := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return "", e
	}
	_, e = f.WriteString(token + "\n")
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		os.Remove(out)
		return "", e
	}
	c.Grants = append(c.Grants, g)
	if e = h.save(c); e != nil {
		os.Remove(out)
		return "", e
	}
	return g.ID, nil
}
func (h *Host) revoke(id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	c, e := h.load()
	if e != nil {
		return e
	}
	found := false
	gs := []Grant{}
	for _, g := range c.Grants {
		if g.ID == id {
			found = true
		} else {
			gs = append(gs, g)
		}
	}
	if !found {
		return errors.New("grant not found")
	}
	c.Grants = gs
	return h.save(c)
}
func (h *Host) remove(id string) error {
	if !validID(id) {
		return errors.New("invalid source id")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	c, e := h.load()
	if e != nil {
		return e
	}
	found := false
	object := ""
	ss := []Source{}
	for _, s := range c.Sources {
		if s.ID == id {
			found = true
			object, _ = sourceObjectID(s)
		} else {
			ss = append(ss, s)
		}
	}
	if !found {
		return errors.New("source not found")
	}
	c.Sources = ss
	c.Revision++
	if e = h.save(c); e != nil {
		return e
	}
	for _, s := range c.Sources {
		if other, ok := sourceObjectID(s); ok && other == object {
			return nil
		}
	}
	if object == "" {
		return nil
	}
	e = os.Remove(filepath.Join(h.dir, "objects", object))
	if os.IsNotExist(e) {
		return nil
	}
	return e
}
func permits(g Grant, scope string) bool {
	for _, s := range g.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}
func authenticate(c Catalog, r *http.Request) (Grant, bool) {
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		return Grant{}, false
	}
	t := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if len(t) != 64 {
		return Grant{}, false
	}
	hash := sha256.Sum256([]byte(t))
	now := time.Now()
	for _, g := range c.Grants {
		b, e := hex.DecodeString(g.Hash)
		exp, ee := time.Parse(time.RFC3339, g.ExpiresAt)
		if e == nil && ee == nil && now.Before(exp) && subtle.ConstantTimeCompare(b, hash[:]) == 1 {
			return g, true
		}
	}
	return Grant{}, false
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
func snippet(s string, n int) string {
	if len(s) <= n {
		return s
	}
	s = s[:n]
	for !utf8.ValidString(s) && len(s) > 0 {
		s = s[:len(s)-1]
	}
	return s
}
func (h *Host) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		respond(w, 405, map[string]string{"error": "read_only"})
		return
	}
	// Reload grants for every request so local revocations apply immediately.
	h.mu.Lock()
	c, e := h.load()
	h.mu.Unlock()
	if e != nil {
		respond(w, 503, map[string]string{"error": "unavailable"})
		return
	}
	g, ok := authenticate(c, r)
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="XAI Base"`)
		respond(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	if r.URL.Path == "/v1/health" {
		respond(w, 200, map[string]any{"ok": true, "id": c.ID, "name": c.Name, "revision": c.Revision, "scopes": g.Scopes})
		return
	}
	if r.URL.Path == "/v1/manifest" {
		if !permits(g, "read") {
			respond(w, 403, map[string]string{"error": "scope_required"})
			return
		}
		budget := maxManifestText
		ss := make([]Source, 0, len(c.Sources))
		for _, s := range c.Sources {
			s.ObjectID = ""
			s.Text = snippet(s.Text, min(16384, budget))
			budget -= len(s.Text)
			ss = append(ss, s)
		}
		respond(w, 200, map[string]any{"id": c.ID, "name": c.Name, "revision": c.Revision, "sources": ss})
		return
	}
	if r.URL.Path == "/v1/search" {
		if !permits(g, "search") {
			respond(w, 403, map[string]string{"error": "scope_required"})
			return
		}
		q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
		if q == "" || len(q) > 1024 {
			respond(w, 400, map[string]string{"error": "query_required_max_1024_bytes"})
			return
		}
		words := strings.Fields(q)
		type hit struct {
			s Source
			n int
		}
		hits := []hit{}
		for _, s := range c.Sources {
			hay := strings.ToLower(s.Name + " " + s.Text)
			score := 0
			for _, word := range words {
				score += strings.Count(hay, word)
			}
			if score > 0 {
				s.ObjectID = ""
				s.Text = snippet(s.Text, 16384)
				hits = append(hits, hit{s, score})
			}
		}
		sort.SliceStable(hits, func(i, j int) bool { return hits[i].n > hits[j].n })
		ss := []Source{}
		for _, v := range hits {
			ss = append(ss, v.s)
			if len(ss) == 10 {
				break
			}
		}
		respond(w, 200, map[string]any{"sources": ss, "revision": c.Revision})
		return
	}
	if strings.HasPrefix(r.URL.Path, "/v1/sources/") {
		if !permits(g, "read") {
			respond(w, 403, map[string]string{"error": "scope_required"})
			return
		}
		id := strings.TrimPrefix(r.URL.Path, "/v1/sources/")
		if !validID(id) {
			respond(w, 404, map[string]string{"error": "not_found"})
			return
		}
		for _, s := range c.Sources {
			if s.ID == id {
				object, ok := sourceObjectID(s)
				if !ok {
					respond(w, 404, map[string]string{"error": "not_found"})
					return
				}
				p := filepath.Join(h.dir, "objects", object)
				info, e := os.Lstat(p)
				if e != nil {
					respond(w, 404, map[string]string{"error": "reference_only"})
					return
				}
				if !info.Mode().IsRegular() {
					respond(w, 404, map[string]string{"error": "not_found"})
					return
				}
				f, e := os.Open(p)
				if e != nil {
					respond(w, 404, map[string]string{"error": "not_found"})
					return
				}
				defer f.Close()
				w.Header().Set("Content-Type", s.MIMEType)
				w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": s.Name}))
				http.ServeContent(w, r, s.Name, info.ModTime(), f)
				return
			}
		}
	}
	respond(w, 404, map[string]string{"error": "not_found"})
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: vortex-base init|import|sync|publish|grant|revoke|delete|status|serve [flags]")
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	dir := fs.String("dir", "", "private Base directory (required)")
	name := fs.String("name", "", "display name (defaults to file name when importing)")
	quota := fs.Int64("quota-mib", 2048, "Base storage quota in MiB")
	file := fs.String("file", "", "file to import")
	snapshot := fs.String("snapshot", "", "local JSON source snapshot for sync/publish")
	jsonOutput := fs.Bool("json", false, "machine-readable output (grant)")
	sourceURL := fs.String("url", "", "document reference URL (HTTPS, no query credentials)")
	textFile := fs.String("text-file", "", "UTF-8 text/transcript file for a document/media reference")
	out := fs.String("out", "", "new token file (0600), never overwritten")
	scope := fs.String("scopes", "read,search", "grant scopes")
	days := fs.Int("days", 30, "grant expiry days, 1–365")
	id := fs.String("id", "", "source or grant ID")
	listen := fs.String("listen", "127.0.0.1:7941", "listen address")
	cert := fs.String("tls-cert", "", "TLS certificate path")
	key := fs.String("tls-key", "", "TLS private key path")
	parentPID := fs.Int("parent-pid", 0, "stop when the launching app exits (managed hosting only)")
	readyFile := fs.String("ready-file", "", "private JSON readiness file removed on shutdown")
	if e := fs.Parse(args[1:]); e != nil {
		return e
	}
	if *dir == "" {
		return errors.New("-dir is required")
	}
	abs, e := filepath.Abs(*dir)
	if e != nil {
		return e
	}
	h := &Host{dir: abs}
	switch args[0] {
	case "init":
		if strings.TrimSpace(*name) == "" {
			*name = "My XAI Base"
		}
		if *quota < 1 || *quota > 1024*1024 {
			return errors.New("quota must be 1–1048576 MiB")
		}
		return h.init(*name, *quota<<20)
	case "import":
		desc := ""
		if *textFile != "" {
			f, e := os.Open(*textFile)
			if e != nil {
				return e
			}
			defer f.Close()
			b, e := io.ReadAll(io.LimitReader(f, maxTextBytes+1))
			if e != nil {
				return e
			}
			if len(b) > maxTextBytes || !utf8.Valid(b) {
				return errors.New("text-file must be UTF-8, up to 1 MiB")
			}
			desc = string(b)
		}
		s, e := h.add(*file, *name, *sourceURL, desc)
		if e == nil {
			fmt.Println("Imported source", s.ID)
		}
		return e
	case "sync", "publish":
		if *snapshot == "" {
			*snapshot = *file
		}
		if *snapshot == "" {
			return errors.New("-snapshot is required")
		}
		c, e := h.syncFile(*snapshot)
		if e == nil {
			b, _ := json.Marshal(map[string]any{"id": c.ID, "name": c.Name, "revision": c.Revision, "sources": len(c.Sources)})
			fmt.Println(string(b))
		}
		return e
	case "grant":
		g, e := h.grant(*name, *out, *scope, *days)
		if e == nil {
			if *jsonOutput {
				c, err := h.load()
				if err != nil {
					return err
				}
				for _, grant := range c.Grants {
					if grant.ID == g {
						b, _ := json.Marshal(map[string]any{"id": g, "tokenFile": *out, "scopes": grant.Scopes, "expiresAt": grant.ExpiresAt})
						fmt.Println(string(b))
						break
					}
				}
			} else {
				fmt.Println("Grant", g, "saved to", *out, "(keep private; revoke with this ID)")
			}
		}
		return e
	case "revoke":
		return h.revoke(*id)
	case "delete":
		return h.remove(*id)
	case "status":
		c, e := h.load()
		if e != nil {
			return e
		}
		type grantStatus struct {
			ID        string   `json:"id"`
			Name      string   `json:"name"`
			Scopes    []string `json:"scopes"`
			ExpiresAt string   `json:"expiresAt"`
		}
		gs := []grantStatus{}
		for _, g := range c.Grants {
			gs = append(gs, grantStatus{g.ID, g.Name, g.Scopes, g.ExpiresAt})
		}
		b, _ := json.MarshalIndent(map[string]any{"id": c.ID, "name": c.Name, "revision": c.Revision, "sources": len(c.Sources), "quotaBytes": c.QuotaBytes, "grants": gs}, "", "  ")
		fmt.Println(string(b))
		return nil
	case "serve":
		return serveWithSignals(h, serveOptions{Listen: *listen, Cert: *cert, Key: *key, ReadyFile: *readyFile, ParentPID: *parentPID})
	default:
		return errors.New("unknown command")
	}
}
func main() {
	if e := run(os.Args[1:]); e != nil {
		log.Print(e)
		os.Exit(1)
	}
}
