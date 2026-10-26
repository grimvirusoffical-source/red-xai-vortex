package bridge

import (
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/ingest"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	"strings"
	"testing"
	"time"
)

func TestAttachmentExtractionUpdatesIndexedContextAndQuota(t *testing.T) {
	s := workspaceServer(t)
	data := []byte("A selected local reference with searchable facts.")
	if e := s.St.PutAttachment(store.Attachment{ID: "extract-fixture", Name: "notes.txt", MIMEType: "text/plain"}, data); e != nil {
		t.Fatal(e)
	}
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Bases = []store.Base{{ID: "base", Name: "Reference", Status: "local", Permissions: store.BasePermissions{Read: true, Search: true}, Sources: []store.Source{{ID: "source", Name: "Notes", AttachmentID: "extract-fixture"}}}}
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", BaseIDs: []string{"base"}}}
	})
	result := s.workspaceIngestionAction(map[string]any{"action": "attachment.extract", "id": "extract-fixture"})
	if result["ok"] != true {
		t.Fatal(result)
	}
	if !strings.Contains(s.workspaceContext("chat", "searchable facts"), "searchable facts") {
		t.Fatal("extract absent from context")
	}
	status := s.workspaceIngestionAction(map[string]any{"action": "ingestion.status"})
	if status["ok"] != true {
		t.Fatal(status)
	}
}
func TestUnavailableSubscribedDocumentDoesNotSupplyStaleContext(t *testing.T) {
	s := workspaceServer(t)
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.Bases = []store.Base{{ID: "base", Name: "Docs", Status: "local", Permissions: store.BasePermissions{Read: true, Search: true}, Sources: []store.Source{{ID: "doc", Name: "Document", Text: "STALE_SECRET_SNAPSHOT", URL: "https://example.com/doc"}}}}
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", BaseIDs: []string{"base"}}}
	})
	if e := s.updateIngestion(func(state *ingestionState) {
		state.Documents = []sourceImport{{BaseID: "base", SourceID: "doc", RefreshOnUse: true, Result: ingest.Result{Status: "unavailable", CheckedAt: time.Now()}, LastError: "access denied"}}
	}); e != nil {
		t.Fatal(e)
	}
	if strings.Contains(s.workspaceContext("chat", "snapshot"), "STALE_SECRET_SNAPSHOT") {
		t.Fatal("revoked document cache entered model context")
	}
	if s.St.WorkspaceSnapshot().Bases[0].Sources[0].Text != "STALE_SECRET_SNAPSHOT" {
		t.Fatal("local review snapshot destroyed")
	}
}
func TestIngestionConfigurationRejectsExecutableOrMissingModel(t *testing.T) {
	s := workspaceServer(t)
	if result := s.workspaceIngestionAction(map[string]any{"action": "ingestion.configure", "whisperModel": "relative-or-missing.bin"}); result["ok"] == true {
		t.Fatal("missing model accepted")
	}
	if result := s.workspaceIngestionAction(map[string]any{"action": "source.fetch", "baseID": "missing", "url": "https://example.com"}); result["ok"] == true {
		t.Fatal("missing Base accepted")
	}
}
