package bridge

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func TestChatForbiddenDoesNotFabricateAssistantReply(t *testing.T) {
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Errorf("wrong gateway request: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"message":"this key may not use model vortex-mini"}}`))
	}))
	defer gateway.Close()

	st := store.OpenAt(t.TempDir())
	st.Settings.BaseURL = gateway.URL + "/v1"
	st.Settings.PlainChat = true // bypass an unavailable RedX Link, not gateway security
	st.SaveChat(store.Chat{ID: "forbidden-chat", Title: "New chat", Updated: time.Now()})
	s := &Server{St: st}
	out := s.chatSend(map[string]any{
		"id": "forbidden-chat", "text": "Please reply", "model": "vortex-mini", "modelExplicit": true,
	})
	errorText, _ := out["error"].(string)
	if !strings.Contains(errorText, "HTTP 403") || !strings.Contains(errorText, "vortex-mini") {
		t.Fatalf("server reason was hidden: %v", out)
	}
	if _, found := out["reply"]; found {
		t.Fatalf("error must not be presented as an assistant completion: %v", out)
	}
	if len(st.Chats) != 1 || len(st.Chats[0].Messages) != 1 ||
		st.Chats[0].Messages[0].Role != "user" || st.Chats[0].Messages[0].Content != "Please reply" {
		t.Fatalf("failed request should keep only the user message: %+v", st.Chats)
	}
}
