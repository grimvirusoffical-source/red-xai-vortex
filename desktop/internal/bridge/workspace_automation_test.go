package bridge

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func automationFixture(t *testing.T, content *string) (*Server, *atomic.Int32) {
	t.Helper()
	calls := &atomic.Int32{}
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": *content}}}})
	}))
	t.Cleanup(host.Close)
	s := workspaceServer(t)
	s.St.Settings = store.Settings{BaseURL: host.URL, PlainChat: true}
	return s, calls
}
func completedFixtureChat() store.Chat {
	return store.Chat{ID: "chat", Title: "Conversation", Messages: []store.Msg{{Role: "user", Content: "I prefer concise code explanations."}, {Role: "assistant", Content: "I will keep code explanations concise."}}}
}
func TestAutomaticMemoryIsOptInReviewableAndQuotaBounded(t *testing.T) {
	content := `{"memories":[{"title":"Explanation style","text":"The user prefers concise code explanations."}],"worldState":""}`
	s, calls := automationFixture(t, &content)
	chat := completedFixtureChat()
	if warning := s.captureCompletedTurn(chat, "", "vortex"); warning != "" || calls.Load() != 0 {
		t.Fatal("capture ran without opt-in")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", SharedMemory: true, MemoryCapture: "review"}}
	})
	if warning := s.captureCompletedTurn(chat, "", "vortex"); warning != "" {
		t.Fatal(warning)
	}
	w := s.St.WorkspaceSnapshot()
	if len(w.Memory.Entries) != 0 || len(w.Proposals) != 1 || w.Proposals[0].Scope != "global" {
		t.Fatal("review mode wrote permanent memory")
	}
	proposal := w.Proposals[0]
	accepted := s.workspaceProposalAction(map[string]any{"action": "proposal.accept", "id": proposal.ID, "text": "Prefers brief explanations with concrete code examples."})
	if accepted["ok"] != true {
		t.Fatal(accepted)
	}
	w = s.St.WorkspaceSnapshot()
	if len(w.Proposals) != 0 || len(w.Memory.Entries) != 1 || w.Memory.Entries[0].Text != "Prefers brief explanations with concrete code examples." || w.Memory.Entries[0].Origin != "approved" {
		t.Fatal("edited approval was not applied")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.ChatSettings[0].MemoryCapture = "save"
		w.Memory.QuotaBytes = 1024
		w.Memory.Entries = []store.MemoryEntry{{ID: "full", Scope: "global", Text: strings.Repeat("x", 1000)}}
	})
	warning := s.captureCompletedTurn(chat, "", "vortex")
	if !strings.Contains(warning, "quota") || len(s.St.WorkspaceSnapshot().Memory.Entries) != 1 {
		t.Fatal("automatic write bypassed quota or destroyed saved memory")
	}
}
func TestAutomaticWorldEvolutionAndMemoryRemainScoped(t *testing.T) {
	content := `{"memories":[{"title":"Character","text":"The player carries a silver compass."}],"worldState":"At the north gate, carrying a silver compass."}`
	s, _ := automationFixture(t, &content)
	chat := completedFixtureChat()
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Worlds = []store.World{{ID: "world", Name: "Adventure", WorldState: "At home.", MemoryEnabled: true}}
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", WorldID: "world", Mode: "roleplay", SharedMemory: false, MemoryCapture: "save", StateEvolution: "review"}}
	})
	if warning := s.captureCompletedTurn(chat, "", "vortex"); warning != "" {
		t.Fatal(warning)
	}
	w := s.St.WorkspaceSnapshot()
	if len(w.Memory.Entries) != 1 || w.Memory.Entries[0].Scope != "world" || w.Memory.Entries[0].ScopeID != "world" || w.Worlds[0].WorldState != "At home." || len(w.Proposals) != 1 || w.Proposals[0].Kind != "worldState" {
		t.Fatal("world capture leaked or bypassed review")
	}
	if r := s.workspaceProposalAction(map[string]any{"action": "proposal.accept", "id": w.Proposals[0].ID}); r["ok"] != true {
		t.Fatal(r)
	}
	if s.St.WorkspaceSnapshot().Worlds[0].WorldState != "At the north gate, carrying a silver compass." {
		t.Fatal("approved world state missing")
	}
	if strings.Contains(s.workspaceContext("unrelated", ""), "compass") {
		t.Fatal("world auto memory leaked to ordinary chat")
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) { w.ChatSettings[0].StateEvolution = "save" })
	content = `{"memories":[],"worldState":"Inside the library."}`
	if warning := s.captureCompletedTurn(chat, "", "vortex"); warning != "" {
		t.Fatal(warning)
	}
	if s.St.WorkspaceSnapshot().Worlds[0].WorldState != "Inside the library." {
		t.Fatal("explicit auto-save state evolution did not run")
	}
}
func TestAutomaticExtractionRejectsUnstructuredOrCredentialContent(t *testing.T) {
	for _, text := range []string{"I will remember that", `{"memories":[{"title":"Access","text":"api_key=private-secret"}],"worldState":""}`, `{"memories":[],"worldState":"password=private"}`} {
		if _, err := parseExtraction(text); err == nil {
			t.Fatalf("unsafe extraction accepted: %s", text)
		}
	}
}

func TestDisabledProjectMemoryCannotFallBackToGlobalCapture(t *testing.T) {
	w := store.NewWorkspace()
	w.Projects = []store.Project{{ID: "project", Name: "Private work", MemoryEnabled: false}}
	scope, id, allowed := captureScope(w, store.ChatSettings{ProjectID: "project", SharedMemory: true, MemoryCapture: "save"})
	if allowed || scope != "project" || id != "project" {
		t.Fatal("project facts could fall through into global automatic memory")
	}
}
func TestStaleWorldProposalRequiresAnEditedReconciliation(t *testing.T) {
	s := workspaceServer(t)
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Worlds = []store.World{{ID: "world", Name: "World", WorldState: "User edited this state."}}
		w.Proposals = []store.Proposal{{ID: "proposal", Kind: "worldState", Scope: "world", ScopeID: "world", Title: "Next state", Text: "An earlier generated state.", OriginalState: "Original state."}}
	})
	result := s.workspaceProposalAction(map[string]any{"action": "proposal.accept", "id": "proposal"})
	if result["ok"] == true || s.St.WorkspaceSnapshot().Worlds[0].WorldState != "User edited this state." {
		t.Fatal("stale proposal overwrote a manual world edit")
	}
	result = s.workspaceProposalAction(map[string]any{"action": "proposal.accept", "id": "proposal", "text": "Reconciled user edit and new story events."})
	if result["ok"] != true || s.St.WorkspaceSnapshot().Worlds[0].WorldState != "Reconciled user edit and new story events." {
		t.Fatal("explicitly edited reconciliation was rejected")
	}
}
func TestFailedModelResponseDoesNotTriggerAutomaticCapture(t *testing.T) {
	var calls atomic.Int32
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"invalid request"}`))
	}))
	defer host.Close()
	s := workspaceServer(t)
	s.St.Settings = store.Settings{BaseURL: host.URL, PlainChat: true}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", SharedMemory: true, MemoryCapture: "save"}}
	})
	result := s.chatSend(map[string]any{"id": "chat", "text": "Hello", "model": "vortex"})
	if msg, _ := result["error"].(string); !strings.Contains(msg, "HTTP 400") ||
		calls.Load() != 1 || len(s.St.WorkspaceSnapshot().Memory.Entries) != 0 {
		t.Fatalf("failed response was hidden or treated as a completed turn: %v", result)
	}
}
