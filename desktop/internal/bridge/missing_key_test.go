package bridge

import (
	"strings"
	"testing"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func keylessServer(t *testing.T) *Server {
	t.Helper()
	st := store.OpenAt(t.TempDir())
	st.Settings.PlainChat = true
	st.Settings.BaseURL = "http://127.0.0.1:1/v1"
	return &Server{St: st, baseCredential: func(string) string { return "" }}
}

func TestStatusReportsMissingModelKeyWithoutGatewayProbe(t *testing.T) {
	s := keylessServer(t)
	out := s.dispatch("status", map[string]any{})
	if out["apiKeySaved"] != false {
		t.Fatalf("apiKeySaved = %#v", out["apiKeySaved"])
	}
	if out["connected"] != false {
		t.Fatalf("connected = %#v", out["connected"])
	}
	models, _ := out["models"].([]string)
	if len(models) != 1 || models[0] != "vortex" {
		t.Fatalf("fallback models = %#v", out["models"])
	}
}

func TestConnectionProbeExplainsMissingModelKey(t *testing.T) {
	s := keylessServer(t)
	out := s.dispatch("settings.probe", map[string]any{})
	if out["ok"] != false || !strings.Contains(strings.ToLower(out["message"].(string)), "model api key") {
		t.Fatalf("probe = %#v", out)
	}
	e2e := s.testVortex()
	if e2e["ok"] != false || !strings.Contains(strings.ToLower(e2e["message"].(string)), "model api key") {
		t.Fatalf("e2e = %#v", e2e)
	}
}

func TestVortexChatStopsLocallyWhenModelKeyMissing(t *testing.T) {
	s := keylessServer(t)
	s.St.SaveChat(store.Chat{ID: "missing-key", Title: "New chat", Updated: time.Now()})
	out := s.chatSend(map[string]any{"id": "missing-key", "text": "hello"})
	if !strings.Contains(strings.ToLower(out["error"].(string)), "model api key") {
		t.Fatalf("chat = %#v", out)
	}
	var found *store.Chat
	for i := range s.St.Chats {
		if s.St.Chats[i].ID == "missing-key" {
			found = &s.St.Chats[i]
			break
		}
	}
	if found == nil || len(found.Messages) != 1 || found.Messages[0].Role != "user" {
		t.Fatalf("user draft was not preserved: %#v", found)
	}
}
