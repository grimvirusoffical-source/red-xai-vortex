package bridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
)

// gw calls the Vortex gateway job queue (/v1/jobs) with the user's API key.
func (s *Server) gw(method, path string, body any) map[string]any {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, strings.TrimRight(s.St.Settings.BaseURL, "/")+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if k := keyring.Get("vortex-api-key"); k != "" {
		req.Header.Set("Authorization", "Bearer "+k)
	}
	res, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	out := map[string]any{}
	json.Unmarshal(b, &out)
	if res.StatusCode >= 300 {
		msg, _ := out["error"].(string)
		if m, ok := out["error"].(map[string]any); ok {
			msg, _ = m["message"].(string)
		}
		return map[string]any{"ok": false, "message": fmt.Sprintf("HTTP %d %s", res.StatusCode, msg)}
	}
	out["ok"] = true
	return out
}

func (s *Server) mediaSubmit(in map[string]any) map[string]any {
	t := str(in, "type")
	p := str(in, "prompt")
	if t == "" || p == "" {
		return map[string]any{"ok": false, "message": "type and prompt required"}
	}
	body := map[string]any{"type": t, "prompt": p}
	if t == "speech" {
		body["input"] = p
	}
	return s.gw("POST", "/jobs", body)
}

func (s *Server) mediaJob(id string) map[string]any { return s.gw("GET", "/jobs/"+id, nil) }
func (s *Server) mediaJobs() map[string]any         { return s.gw("GET", "/jobs", nil) }
