package bridge

import (
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/ingest"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func TestManagedHostPublishesSyncsAndRevokes(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "vortex-base")
	sourceDir, err := filepath.Abs("../../../bases")
	if err != nil {
		t.Fatal(err)
	}
	build := exec.Command("go", "build", "-buildvcs=false", "-o", helper, ".")
	build.Dir = sourceDir
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build helper: %v %s", err, output)
	}
	t.Setenv("VORTEX_BASE_HELPER", helper)
	s := workspaceServer(t)
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Bases = []store.Base{{ID: "local-base", Name: "Published notes", Status: "local", Permissions: store.BasePermissions{Read: true, Search: true}, Sources: []store.Source{{ID: "note", Name: "Note", Kind: "text", MIMEType: "text/plain", Text: "FIRST_REVISION"}}}}
	})
	result := s.workspaceHostAction(map[string]any{"action": "host.start", "id": "local-base"})
	if result["ok"] != true {
		t.Fatal(result)
	}
	t.Cleanup(func() { _ = s.stopManagedHost("local-base", false) })
	status := result["hosting"].(hostingStatus)
	if !status.Running || !strings.HasPrefix(status.Endpoint, "http://127.0.0.1:") || status.SourceCount != 1 {
		t.Fatalf("host readiness missing: %+v", status)
	}
	result = s.workspaceHostAction(map[string]any{"action": "host.grant", "id": "local-base", "name": "Reader", "days": float64(1), "scopes": []any{"read", "search"}})
	if result["ok"] != true {
		t.Fatal(result)
	}
	invite := result["invite"].(map[string]any)
	token := invite["token"].(string)
	grantID := invite["grantID"].(string)
	if token == "" || grantID == "" {
		t.Fatal("invite lacks private credential or revocation ID")
	}
	getManifest := func() (int, string) {
		req, _ := http.NewRequest("GET", status.Endpoint+"/v1/manifest", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		var document map[string]any
		_ = json.NewDecoder(response.Body).Decode(&document)
		raw, _ := json.Marshal(document)
		return response.StatusCode, string(raw)
	}
	if code, text := getManifest(); code != 200 || !strings.Contains(text, "FIRST_REVISION") {
		t.Fatal("initial publication unavailable")
	}
	save := s.workspaceSave(map[string]any{"kind": "base", "value": map[string]any{"id": "local-base", "name": "Updated notes", "permissions": map[string]any{"read": true, "search": true}, "sources": []any{map[string]any{"id": "second", "name": "New note", "kind": "text", "mimeType": "text/plain", "text": "SECOND_REVISION"}}}})
	if save["ok"] != true {
		t.Fatal(save)
	}
	if code, text := getManifest(); code != 200 || !strings.Contains(text, "SECOND_REVISION") || strings.Contains(text, "FIRST_REVISION") {
		t.Fatal("local edits/deletions did not auto-sync")
	}
	if err := s.updateIngestion(func(state *ingestionState) {
		state.Documents = []sourceImport{{BaseID: "local-base", SourceID: "second", RefreshOnUse: true, Result: ingest.Result{Status: "unavailable"}}}
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.syncStartedHosts(); err != nil {
		t.Fatal(err)
	}
	if code, text := getManifest(); code != 200 || strings.Contains(text, "SECOND_REVISION") {
		t.Fatal("unavailable subscribed document remained published")
	}
	if result = s.workspaceHostAction(map[string]any{"action": "host.revoke", "id": "local-base", "grantID": grantID}); result["ok"] != true {
		t.Fatal(result)
	}
	if code, _ := getManifest(); code != 401 {
		t.Fatalf("revoked invite still authorized: %d", code)
	}
	result = s.workspaceHostAction(map[string]any{"action": "host.stop", "id": "local-base"})
	if result["ok"] != true || result["hosting"].(hostingStatus).Running {
		t.Fatal("managed host did not stop")
	}
	if s.St.WorkspaceSnapshot().Bases[0].Hosting.Enabled {
		t.Fatal("explicit stop would restart hosting")
	}
	raw, _ := os.ReadFile(filepath.Join(s.St.Dir, "workspace.json"))
	if strings.Contains(string(raw), token) {
		t.Fatal("invite credential persisted in workspace metadata")
	}
}
func TestManagedHostRequiresExplicitTLSForRemoteListeners(t *testing.T) {
	for _, config := range []store.HostingConfig{{Listen: "0.0.0.0:7000"}, {Listen: "192.168.1.2:7000"}, {Listen: "127.0.0.1:0", PublicEndpoint: "http://unsafe.example"}} {
		if _, err := validateHostConfig(config); err == nil {
			t.Fatal("unsafe listener configuration accepted")
		}
	}
}
