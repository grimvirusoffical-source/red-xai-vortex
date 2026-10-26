package bridge

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func TestPatchReviewAndApprovalApplyExactChange(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "main.txt")
	_ = os.WriteFile(path, []byte("before\n"), 0600)
	s := workspaceServer(t)
	mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
		w.ChatSettings = []store.ChatSettings{{ChatID: "chat", Mode: "code", Coding: store.CodingContext{RepoPath: root}}}
	})
	patch := "diff --git a/main.txt b/main.txt\n--- a/main.txt\n+++ b/main.txt\n@@ -1 +1 @@\n-before\n+after\n"
	result := s.workspacePatchAction(map[string]any{"action": "coding.patch.review", "chatID": "chat", "patch": patch})
	if result["ok"] != true || !result["review"].(patchReview).CheckPassed {
		t.Fatal(result)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "before\n" {
		t.Fatal("review changed files")
	}
	result = s.workspacePatchAction(map[string]any{"action": "coding.patch.apply", "chatID": "chat", "patch": patch})
	if result["ok"] != true {
		t.Fatal(result)
	}
	id := result["runID"].(string)
	data, _ = os.ReadFile(path)
	if string(data) != "before\n" {
		t.Fatal("patch applied before approval")
	}
	s.approve(id, true)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		runs.mu.Lock()
		status := runs.runs[id].Status
		runs.mu.Unlock()
		if status == "done" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	data, _ = os.ReadFile(path)
	if string(data) != "after\n" {
		t.Fatal("approved patch was not applied")
	}
}
func TestPatchRejectsSecretsSymlinksAndTraversal(t *testing.T) {
	root := t.TempDir()
	_ = os.WriteFile(filepath.Join(root, ".env"), []byte("private\n"), 0600)
	_ = os.Symlink(filepath.Join(root, ".env"), filepath.Join(root, "alias.txt"))
	for _, name := range []string{"../outside", ".env", "alias.txt", ".git/config"} {
		patch := "--- a/" + name + "\n+++ b/" + name + "\n@@ -1 +1 @@\n-before\n+after\n"
		if _, err := validatePatch(root, patch); err == nil {
			t.Fatalf("unsafe patch path accepted: %s", name)
		}
	}
}
