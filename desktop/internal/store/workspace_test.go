package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWorkspaceMigrationPreservesLegacyState(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".config", "red-xai-vortex")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	oldChat := []Chat{{ID: "old", Title: "Existing chat", Kind: "party", Members: []string{"a", "b"}, Composer: &Composer{Tier: "vortex-pro", Length: "long"}, Messages: []Msg{{Role: "user", Content: "Keep this message"}}, Updated: time.Now().UTC()}}
	oldSettings := Settings{BaseURL: "https://example.org/v1", ActiveID: "kept-agent", NoAutoUpdate: true, PlainChat: true, PhoneChat: false, LinkServer: "custom.local:9000"}
	for name, value := range map[string]any{"chats.json": oldChat, "settings.json": oldSettings, "agents.json": []Agent{{ID: "kept-agent", Name: "Kept", Model: "custom-model"}}} {
		raw, _ := json.Marshal(value)
		if err := os.WriteFile(filepath.Join(dir, name), raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	st := OpenAt(dir)
	if len(st.Chats) != 1 || st.Chats[0].Messages[0].Content != "Keep this message" || st.Chats[0].Composer.Tier != "vortex-pro" || st.Settings != oldSettings || st.Agents[0].Model != "custom-model" {
		t.Fatal("legacy state changed during additive migration")
	}
	if st.Workspace.Version != 1 || st.Workspace.Memory.QuotaBytes != DefaultMemoryQuota {
		t.Fatal("workspace defaults missing")
	}
	if err := st.UpdateWorkspace(func(w *Workspace) error {
		w.Projects = append(w.Projects, Project{ID: "p", Name: "New project"})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	reopened := OpenAt(dir)
	if len(reopened.Workspace.Projects) != 1 || reopened.Chats[0].Title != "Existing chat" {
		t.Fatal("workspace or chats did not survive reopen")
	}
}
func TestWorkspaceQuotaTransactionAndAttachmentAccounting(t *testing.T) {
	st := &Store{Dir: t.TempDir(), Workspace: NewWorkspace()}
	a := Attachment{ID: "attachment-1", Name: "notes.txt", Bytes: 800}
	if err := st.PutAttachment(a, make([]byte, 800)); err != nil {
		t.Fatal(err)
	}
	if err := st.UpdateWorkspace(func(w *Workspace) error {
		w.Memory.QuotaBytes = 1024
		w.Memory.Entries = []MemoryEntry{{ID: "m", Title: "Note", Text: strings.Repeat("x", 100), Scope: "global", AttachmentIDs: []string{a.ID, a.ID}}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if usage := st.WorkspaceSnapshot().MemoryUsage(); usage != 904 {
		t.Fatalf("shared attachment counted twice: %d", usage)
	}
	err := st.UpdateWorkspace(func(w *Workspace) error { w.Memory.Entries[0].Text = strings.Repeat("x", 1000); return nil })
	if err == nil {
		t.Fatal("quota overflow accepted")
	}
	if st.WorkspaceSnapshot().MemoryUsage() != 904 {
		t.Fatal("failed quota mutation was applied")
	}
	if err = st.DeleteAttachment(a.ID); err == nil {
		t.Fatal("referenced attachment deleted")
	}
	raw, _ := os.ReadFile(filepath.Join(st.Dir, "workspace.json"))
	var disk Workspace
	if err = json.Unmarshal(raw, &disk); err != nil || disk.MemoryUsage() != 904 {
		t.Fatal("failed write changed persisted state")
	}
	if _, err = st.AttachmentData("../workspace.json"); err == nil {
		t.Fatal("path traversal accepted")
	}
}
func TestCorruptAndFutureWorkspacePreserved(t *testing.T) {
	for _, raw := range []string{"not json", `{"version":99,"memory":{"quotaBytes":1024}}`} {
		t.Run(raw, func(t *testing.T) {
			home := t.TempDir()
			dir := filepath.Join(home, ".config", "red-xai-vortex")
			_ = os.MkdirAll(dir, 0700)
			_ = os.WriteFile(filepath.Join(dir, "workspace.json"), []byte(raw), 0600)
			st := OpenAt(dir)
			if st.WorkspaceError == "" {
				t.Fatal("corrupt workspace not reported")
			}
			if err := st.UpdateWorkspace(func(w *Workspace) error { w.Projects = []Project{{ID: "p", Name: "unsafe overwrite"}}; return nil }); err == nil {
				t.Fatal("corrupt workspace overwritten")
			}
			after, _ := os.ReadFile(filepath.Join(dir, "workspace.json"))
			if string(after) != raw {
				t.Fatal("original workspace was changed")
			}
		})
	}
}
func TestWorkspaceSnapshotIsIndependent(t *testing.T) {
	st := &Store{Dir: t.TempDir(), Workspace: NewWorkspace()}
	_ = st.UpdateWorkspace(func(w *Workspace) error {
		w.Memory.Entries = []MemoryEntry{{ID: "m", Text: "original", Scope: "global"}}
		return nil
	})
	snapshot := st.WorkspaceSnapshot()
	snapshot.Memory.Entries[0].Text = "mutated"
	if st.WorkspaceSnapshot().Memory.Entries[0].Text != "original" {
		t.Fatal("snapshot mutated store")
	}
}

func TestExtractedTextCountsTowardQuotaAndCanBeRecoveredAfterUpgrade(t *testing.T) {
	dir := t.TempDir()
	st := OpenAt(dir)
	if err := st.UpdateWorkspace(func(w *Workspace) error {
		w.Memory.QuotaBytes = 1024
		w.Attachments = []Attachment{{ID: "a", Bytes: 500, Text: strings.Repeat("x", 600)}}
		w.Memory.Entries = []MemoryEntry{{ID: "m", Scope: "global", AttachmentIDs: []string{"a"}}}
		return nil
	}); err == nil {
		t.Fatal("extracted text bypassed memory quota")
	}
	// A pre-upgrade quota may be exceeded once extracted text starts counting.
	// Preserve the content and permit the user to raise the quota or remove it.
	raw := NewWorkspace()
	raw.Memory.QuotaBytes = 1024
	raw.Attachments = []Attachment{{ID: "a", Bytes: 500, Text: strings.Repeat("x", 600)}}
	raw.Memory.Entries = []MemoryEntry{{ID: "m", Scope: "global", AttachmentIDs: []string{"a"}}}
	data, _ := json.Marshal(raw)
	if err := os.WriteFile(filepath.Join(st.Dir, "workspace.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	reopened := OpenAt(dir)
	if reopened.WorkspaceError != "" || len(reopened.Workspace.Memory.Entries) != 1 {
		t.Fatal("over-quota migrated memory became unrecoverable")
	}
	if err := reopened.UpdateWorkspace(func(w *Workspace) error { w.Memory.QuotaBytes = 2048; return nil }); err != nil {
		t.Fatal(err)
	}
}
