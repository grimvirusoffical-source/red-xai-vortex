package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T) (*Host, string, string) {
	t.Helper()
	h := &Host{dir: t.TempDir()}
	if e := h.init("Shared reference", 8<<20); e != nil {
		t.Fatal(e)
	}
	p := filepath.Join(t.TempDir(), "token")
	id, e := h.grant("Reader", p, "read,search", 1)
	if e != nil {
		t.Fatal(e)
	}
	b, e := os.ReadFile(p)
	if e != nil {
		t.Fatal(e)
	}
	return h, strings.TrimSpace(string(b)), id
}
func request(h *Host, token, method, path string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestAuthenticatedLifecycle(t *testing.T) {
	h, token, grant := fixture(t)
	for _, path := range []string{"/v1/health", "/v1/manifest", "/v1/search?q=code", "/v1/sources/abc"} {
		if w := request(h, "", http.MethodGet, path); w.Code != 401 {
			t.Fatalf("unauth %s: %d", path, w.Code)
		}
	}
	p := filepath.Join(t.TempDir(), "code.txt")
	os.WriteFile(p, []byte("Project deployment requires a review.\nGo coding context."), 0600)
	s, e := h.add(p, "Project notes", "", "")
	if e != nil {
		t.Fatal(e)
	}
	w := request(h, token, "GET", "/v1/manifest")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Go coding context") || strings.Contains(w.Body.String(), h.dir) || strings.Contains(w.Body.String(), token) {
		t.Fatalf("bad manifest: %d %s", w.Code, w.Body.String())
	}
	w = request(h, token, "GET", "/v1/search?q=coding")
	if w.Code != 200 || !strings.Contains(w.Body.String(), s.ID) {
		t.Fatal(w.Body.String())
	}
	w = request(h, token, "GET", "/v1/sources/"+s.ID)
	if w.Code != 200 || !strings.HasPrefix(w.Header().Get("Content-Disposition"), "attachment;") {
		t.Fatalf("download: %d", w.Code)
	}
	if e = h.remove(s.ID); e != nil {
		t.Fatal(e)
	}
	if w = request(h, token, "GET", "/v1/sources/"+s.ID); w.Code != 404 {
		t.Fatalf("deleted source accessible: %d", w.Code)
	}
	if e = h.revoke(grant); e != nil {
		t.Fatal(e)
	}
	if w = request(h, token, "GET", "/v1/health"); w.Code != 401 {
		t.Fatalf("revoked token accepted: %d", w.Code)
	}
}
func TestScopesExpiryAndReadOnly(t *testing.T) {
	h, token, _ := fixture(t)
	p := filepath.Join(t.TempDir(), "search-token")
	id, e := h.grant("Search only", p, "search", 1)
	if e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(p)
	search := strings.TrimSpace(string(b))
	if w := request(h, search, "GET", "/v1/manifest"); w.Code != 403 {
		t.Fatalf("scope bypass: %d", w.Code)
	}
	if w := request(h, search, "GET", "/v1/search?q=test"); w.Code != 200 {
		t.Fatalf("search scope denied: %d", w.Code)
	}
	c, _ := h.load()
	for i := range c.Grants {
		if c.Grants[i].ID == id {
			c.Grants[i].ExpiresAt = "2000-01-01T00:00:00Z"
		}
	}
	h.save(c)
	if w := request(h, search, "GET", "/v1/health"); w.Code != 401 {
		t.Fatalf("expired token: %d", w.Code)
	}
	for _, method := range []string{"POST", "PUT", "DELETE"} {
		if w := request(h, token, method, "/v1/manifest"); w.Code != 405 {
			t.Fatalf("mutable API: %s %d", method, w.Code)
		}
	}
	if w := request(h, token, "GET", "/v1/sources/../../catalog.json"); w.Code != 404 {
		t.Fatalf("path traversal: %d", w.Code)
	}
	if w := request(h, token, "GET", "/v1/search"); w.Code != 400 {
		t.Fatalf("unbounded empty search: %d", w.Code)
	}
}
func TestQuotaReferencesAndPrivateTokens(t *testing.T) {
	h, _, _ := fixture(t)
	c, _ := h.load()
	c.QuotaBytes = 8
	h.save(c)
	if _, e := h.add("", "Oversize", "https://docs.google.com/document/d/example/edit", "too much text"); e == nil {
		t.Fatal("quota bypass")
	}
	s, e := h.add("", "Doc", "https://docs.google.com/document/d/example/edit", "notes")
	if e != nil {
		t.Fatal(e)
	}
	if s.Kind != "document" || s.Text != "notes" {
		t.Fatal(s)
	}
	for _, u := range []string{"http://example.com", "https://user:password@example.com", "https://example.com/doc?token=secret"} {
		if _, e = h.add("", "Bad", u, ""); e == nil {
			t.Fatalf("accepted sensitive URL: %s", u)
		}
	}
	p := filepath.Join(t.TempDir(), "credential")
	os.WriteFile(p, []byte("preserve me"), 0600)
	if _, e = h.grant("No overwrite", p, "read", 1); e == nil {
		t.Fatal("credential overwritten")
	}
	b, _ := os.ReadFile(p)
	if string(b) != "preserve me" {
		t.Fatal("credential lost")
	}
	if e = h.init("Again", 100); e == nil {
		t.Fatal("existing Base reinitialized")
	}
	b, _ = os.ReadFile(filepath.Join(h.dir, "catalog.json"))
	if strings.Contains(string(b), "Bearer ") {
		t.Fatal("plaintext token in catalog")
	}
	info, _ := os.Stat(filepath.Join(h.dir, "catalog.json"))
	if info.Mode().Perm() != 0600 {
		t.Fatal("catalog not private")
	}
}
func TestBoundedManifestAndSymlinkDownload(t *testing.T) {
	h, token, _ := fixture(t)
	c, _ := h.load()
	large := strings.Repeat("reference ", 3000)
	for i := 0; i < 100; i++ {
		c.Sources = append(c.Sources, Source{ID: uid(), Name: "Reference", Text: large, Kind: "text"})
	}
	h.save(c)
	w := request(h, token, "GET", "/v1/manifest")
	var manifest struct {
		Sources []Source `json:"sources"`
	}
	if e := json.Unmarshal(w.Body.Bytes(), &manifest); e != nil {
		t.Fatal(e)
	}
	total := 0
	for _, s := range manifest.Sources {
		if len(s.Text) > 16384 {
			t.Fatal("per-source bound")
		}
		total += len(s.Text)
	}
	if total > maxManifestText {
		t.Fatal("manifest budget exceeded")
	}
	secret := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(secret, []byte("private"), 0600)
	id := c.Sources[0].ID
	os.Symlink(secret, filepath.Join(h.dir, "objects", id))
	if w = request(h, token, "GET", "/v1/sources/"+id); w.Code != 404 {
		t.Fatal("symlink served")
	}
}
func TestRemotePlaintextRefused(t *testing.T) {
	h, _, _ := fixture(t)
	if e := run([]string{"serve", "-dir", h.dir, "-listen", "0.0.0.0:0"}); e == nil || !strings.Contains(e.Error(), "require") {
		t.Fatal("remote plaintext allowed")
	}
}

func TestIndexCapacityCannotMakeExistingCatalogUnreadable(t *testing.T) {
	h, token, _ := fixture(t)
	c, err := h.load()
	if err != nil {
		t.Fatal(err)
	}
	c.Sources = append(c.Sources, Source{ID: uid(), Name: "Oversized index", Text: strings.Repeat("x", maxCatalogBytes)})
	if err = h.save(c); err == nil {
		t.Fatal("oversized catalog was written")
	}
	if _, err = h.load(); err != nil {
		t.Fatal("previous catalog was not preserved", err)
	}
	if w := request(h, token, "GET", "/v1/manifest"); w.Code != 200 {
		t.Fatal("existing Base stopped working")
	}
}
