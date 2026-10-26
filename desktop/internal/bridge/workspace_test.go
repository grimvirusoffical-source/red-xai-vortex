package bridge

import (
	"context"
	"encoding/json"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/activity"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func workspaceServer(t *testing.T) *Server {
	t.Helper()
	return &Server{St: &store.Store{Dir: t.TempDir(), Workspace: store.NewWorkspace(), Chats: []store.Chat{{ID: "chat", Title: "Existing chat"}}}, baseCredential: func(string) string { return "test-only-token" }}
}
func mustWorkspaceUpdate(t *testing.T, s *Server, fn func(*store.Workspace)) {
	t.Helper()
	if err := s.St.UpdateWorkspace(func(w *store.Workspace) error { fn(w); return nil }); err != nil {
		t.Fatal(err)
	}
}
func TestContextScopesAndWorldIsolation(t *testing.T) {
	s := workspaceServer(t)
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Projects = []store.Project{{ID: "p", Name: "Project", MemoryEnabled: true}, {ID: "other", Name: "Other"}}
		w.Worlds = []store.World{{ID: "world", Name: "World", Lore: "WORLD_LORE", MemoryEnabled: true}, {ID: "other-world", Name: "Other"}}
		w.Memory.Entries = []store.MemoryEntry{{ID: "g", Text: "GLOBAL_SECRET", Scope: "global"}, {ID: "p", Text: "PROJECT_SECRET", Scope: "project", ScopeID: "p"}, {ID: "o", Text: "OTHER_PROJECT_SECRET", Scope: "project", ScopeID: "other"}, {ID: "w", Text: "WORLD_SECRET", Scope: "world", ScopeID: "world"}, {ID: "ow", Text: "OTHER_WORLD_SECRET", Scope: "world", ScopeID: "other-world"}}
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", ProjectID: "p", SharedMemory: false}}
	})
	context := s.workspaceContext("chat", "")
	if !strings.Contains(context, "PROJECT_SECRET") || strings.Contains(context, "GLOBAL_SECRET") || strings.Contains(context, "WORLD_SECRET") || strings.Contains(context, "OTHER_PROJECT_SECRET") {
		t.Fatalf("chat scope leak: %s", context)
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) { w.ChatSettings[0].SharedMemory = true })
	if !strings.Contains(s.workspaceContext("chat", ""), "GLOBAL_SECRET") {
		t.Fatal("enabled shared memory omitted")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.ChatSettings[0].WorldID = "world"
		w.ChatSettings[0].Mode = "roleplay"
		w.ChatSettings[0].SharedMemory = false
	})
	context = s.workspaceContext("chat", "")
	if !strings.Contains(context, "WORLD_SECRET") || !strings.Contains(context, "WORLD_LORE") || strings.Contains(context, "GLOBAL_SECRET") || strings.Contains(context, "PROJECT_SECRET") || strings.Contains(context, "OTHER_WORLD_SECRET") {
		t.Fatalf("world isolation leak: %s", context)
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) { w.ChatSettings[0].SharedMemory = true })
	if !strings.Contains(s.workspaceContext("chat", ""), "GLOBAL_SECRET") {
		t.Fatal("explicit roleplay shared-memory opt-in was ignored")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) { w.Worlds[0].MemoryEnabled = false })
	if strings.Contains(s.workspaceContext("chat", ""), "WORLD_SECRET") {
		t.Fatal("disabled world memory included")
	}
	if strings.Contains(s.workspaceContext("unknown", ""), "SECRET") {
		t.Fatal("legacy chat inherited context without consent")
	}
}
func TestRemoteRevocationDropsCachedContextAndNoCredentialLeak(t *testing.T) {
	denied := false
	requests := 0
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.Header.Get("Authorization") != "Bearer test-only-token" {
			t.Error("authenticated request missing")
		}
		if denied {
			http.Error(w, "denied", 403)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"id": "remote-id", "name": "Remote Base", "revision": 1, "sources": []store.Source{{ID: "s", Name: "Knowledge", Kind: "text", Text: "REMOTE_REFERENCE"}}})
	}))
	defer host.Close()
	s := workspaceServer(t)
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Bases = []store.Base{{ID: "base", Name: "Connected Base", Endpoint: host.URL, RemoteID: "remote-id", Status: "online", Permissions: store.BasePermissions{Read: true, Search: true}, Sources: []store.Source{{ID: "s", Name: "Cached", Text: "OLD_CACHE"}}}}
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", BaseIDs: []string{"base"}}}
	})
	context := s.workspaceContext("chat", "")
	if !strings.Contains(context, "REMOTE_REFERENCE") || strings.Contains(context, "OLD_CACHE") || strings.Contains(context, host.URL) || strings.Contains(context, "test-only-token") {
		t.Fatalf("bad remote context: %s", context)
	}
	denied = true
	context = s.workspaceContext("chat", "")
	if strings.Contains(context, "REMOTE_REFERENCE") || strings.Contains(context, "OLD_CACHE") {
		t.Fatal("revoked remote cache was used")
	}
	base := s.St.WorkspaceSnapshot().Bases[0]
	if base.Status != "offline" || len(base.Sources) != 0 || requests != 2 {
		t.Fatalf("revocation did not update status: %+v requests=%d", base, requests)
	}
	raw, _ := json.Marshal(s.workspaceResult())
	if strings.Contains(string(raw), "test-only-token") {
		t.Fatal("credential leaked in API state")
	}
}
func TestRemoteCredentialsDoNotFollowRedirects(t *testing.T) {
	leaked := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked = true; w.Write([]byte(`{}`)) }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, http.StatusFound) }))
	defer redirect.Close()
	s := workspaceServer(t)
	var out any
	err := s.remoteBaseJSON(store.Base{ID: "b", Endpoint: redirect.URL}, "/v1/manifest", &out)
	if err == nil || leaked {
		t.Fatal("credential request followed redirect")
	}
	for _, endpoint := range []string{"http://192.168.1.2:8000", "https://user:pass@example.org", "https://example.org?token=x", "https://example.org/v1", "file:///tmp/base"} {
		if _, err := validateBaseEndpoint(endpoint); err == nil {
			t.Fatalf("unsafe endpoint accepted: %s", endpoint)
		}
	}
}
func TestWorkspaceOriginAndBodyLimits(t *testing.T) {
	s := workspaceServer(t)
	call := func(origin, contentType, body string) int {
		r := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8080/bridge/workspace.get", strings.NewReader(body))
		r.Header.Set("Content-Type", contentType)
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		s.handle(w, r)
		return w.Code
	}
	if code := call("http://127.0.0.1:8080", "application/json", `{}`); code != 200 {
		t.Fatalf("same origin rejected: %d", code)
	}
	for _, origin := range []string{"https://malicious.example", "null", "http://127.0.0.1:9000"} {
		if code := call(origin, "application/json", `{}`); code != 403 {
			t.Fatalf("cross origin %q accepted: %d", origin, code)
		}
	}
	if code := call("", "text/plain", `{}`); code != 403 {
		t.Fatal("simple cross-site content type accepted")
	}
	if code := call("", "application/json", `{`); code != 400 {
		t.Fatal("malformed JSON accepted")
	}
	if code := call("", "application/json", strings.Repeat("x", (4<<20)+1)); code != 413 {
		t.Fatal("oversized workspace body accepted")
	}
}
func TestPersonalitiesAndSourceCredentialURLs(t *testing.T) {
	s := workspaceServer(t)
	result := s.workspaceAction(map[string]any{"action": "personality.import", "json": `{"format":"vortex-personality","version":1,"personality":{"id":"untrusted","name":"Careful coder","instructions":"Review changes carefully"}}`})
	if result["ok"] != true {
		t.Fatal(result)
	}
	p := s.St.WorkspaceSnapshot().Personalities[0]
	if p.ID == "untrusted" {
		t.Fatal("import reused untrusted identity")
	}
	export := s.workspaceAction(map[string]any{"action": "personality.export", "id": p.ID})
	if export["ok"] != true || !strings.Contains(export["json"].(string), "Review changes carefully") {
		t.Fatal(export)
	}
	for _, u := range []string{"https://host/document?access_token=secret", "https://u:p@host/doc", "javascript:alert(1)"} {
		if err := validateSource(store.Source{Name: "Source", URL: u}); err == nil {
			t.Fatalf("source credential URL accepted: %s", u)
		}
	}
	if err := validateSource(store.Source{Name: "Google Doc", Kind: "google-doc", URL: "https://docs.google.com/document/d/example/edit", Text: "User exported text"}); err != nil {
		t.Fatal(err)
	}
}
func TestCodingInspectSelectedFilesOnlyAndTraversal(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	_ = os.WriteFile(filepath.Join(root, "main.go"), []byte("package main\n"), 0600)
	_ = os.WriteFile(filepath.Join(root, ".env"), []byte("SECRET=private"), 0600)
	_ = os.WriteFile(filepath.Join(outside, "private.txt"), []byte("OUTSIDE_SECRET"), 0600)
	_ = os.Symlink(filepath.Join(outside, "private.txt"), filepath.Join(root, "escape.txt"))
	_ = os.Symlink(filepath.Join(root, ".env"), filepath.Join(root, "innocent.txt"))
	_ = os.Mkdir(filepath.Join(root, "folder"), 0700)
	s := workspaceServer(t)
	r := s.workspaceInspect(map[string]any{"repoPath": root, "paths": []any{"main.go"}})
	if r["ok"] != true {
		t.Fatal(r)
	}
	coding := r["coding"].(store.CodingContext)
	if len(coding.Files) != 1 || coding.Files[0].Language != "go" || coding.Files[0].Content != "package main\n" {
		t.Fatal("selected file context missing")
	}
	for _, path := range []string{"../private.txt", ".env", "escape.txt", "innocent.txt", "folder"} {
		r = s.workspaceInspect(map[string]any{"repoPath": root, "paths": []any{path}})
		if r["ok"] == true {
			t.Fatalf("unsafe context file accepted: %s", path)
		}
	}
}
func TestChatCompletionUsesOnlyEnabledWorkspaceContext(t *testing.T) {
	var messages []map[string]string
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Messages []map[string]string `json:"messages"`
		}
		json.NewDecoder(r.Body).Decode(&in)
		messages = in.Messages
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"choices":[{"message":{"content":"Reply"}}]}`))
	}))
	defer gateway.Close()
	s := workspaceServer(t)
	s.St.Settings = store.Settings{BaseURL: gateway.URL, PlainChat: true}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Memory.Entries = []store.MemoryEntry{{ID: "m", Title: "Note", Text: "SELECTED_MEMORY", Scope: "global"}}
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", SharedMemory: true}}
	})
	r := s.chatSend(map[string]any{"id": "chat", "text": "Hello", "model": "vortex"})
	if r["reply"] != "Reply" {
		t.Fatal(r)
	}
	raw, _ := json.Marshal(messages)
	if !strings.Contains(string(raw), "SELECTED_MEMORY") {
		t.Fatal("selected memory not forwarded to model")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) { w.ChatSettings[0].SharedMemory = false })
	r = s.chatSend(map[string]any{"id": "chat", "text": "Hello again", "model": "vortex"})
	raw, _ = json.Marshal(messages)
	if strings.Contains(string(raw), "SELECTED_MEMORY") {
		t.Fatal("disabled shared memory forwarded")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) { w.ChatSettings[0].SharedMemory = true })
	s.Act = activity.Open(s.St.Dir)
	run := &Run{ID: "workspace-test-run", ChatID: "chat", Task: "Review code", Agent: "Assistant", Status: "running"}
	s.loop(context.Background(), run, member{ID: "model:vortex", Name: "Assistant", Model: "vortex"}, nil)
	raw, _ = json.Marshal(messages)
	if run.Status != "done" || !strings.Contains(string(raw), "SELECTED_MEMORY") {
		t.Fatal("tool-oriented run omitted selected workspace context")
	}
}
