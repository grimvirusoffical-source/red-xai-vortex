package bridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/activity"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

type Server struct {
	St   *store.Store
	Act  *activity.Log
	Addr string
	ln   net.Listener
}

func Start(st *store.Store) (*Server, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	s := &Server{St: st, Act: activity.Open(st.Dir), Addr: "http://" + ln.Addr().String(), ln: ln}
	mux := http.NewServeMux()
	mux.HandleFunc("/bridge/", s.handle)
	mux.Handle("/", http.FileServer(http.Dir(frontendDir())))
	go http.Serve(ln, mux)
	return s, nil
}

func frontendDir() string {
	if d := os.Getenv("VORTEX_FRONTEND"); d != "" {
		return d
	}
	exe, _ := os.Executable()
	cand := []string{
		filepath.Join(filepath.Dir(exe), "frontend"),
		filepath.Join(filepath.Dir(exe), "..", "frontend"),
		"/workspace/vortex-public/desktop/frontend",
	}
	for _, c := range cand {
		if _, err := os.Stat(filepath.Join(c, "index.html")); err == nil {
			return c
		}
	}
	return "."
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	method := strings.TrimPrefix(r.URL.Path, "/bridge/")
	var in map[string]any
	json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in)
	if in == nil {
		in = map[string]any{}
	}
	out := s.dispatch(method, in)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

func (s *Server) dispatch(m string, in map[string]any) map[string]any {
	switch m {
	case "status":
		models, connected := s.listModels()
		return map[string]any{
			"ok": true, "connected": connected, "baseURL": s.St.Settings.BaseURL, "autoUpdate": !s.St.Settings.NoAutoUpdate,
			"agents": s.St.Agents, "models": models, "chats": chatSummaries(s.St.Chats),
		}
	case "settings.save":
		st := s.St.Settings
		if u, _ := in["baseURL"].(string); u != "" {
			st.BaseURL = strings.TrimRight(u, "/")
		}
		if au, ok := in["autoUpdate"].(bool); ok {
			st.NoAutoUpdate = !au
		}
		if k, _ := in["apiKey"].(string); k != "" {
			_ = keyring.Set("vortex-api-key", strings.TrimSpace(k))
		}
		s.St.SetSettings(st)
		return map[string]any{"ok": true, "message": "Saved. Key stored in OS credential store."}
	case "settings.probe":
		models, ok := s.listModels()
		if !ok {
			return map[string]any{"ok": false, "message": "Could not reach gateway /v1/models"}
		}
		hasV := false
		for _, x := range models {
			if x == "vortex" {
				hasV = true
			}
		}
		msg := fmt.Sprintf("OK — %d models", len(models))
		if hasV {
			msg += " (vortex present)"
		}
		return map[string]any{"ok": true, "message": msg}
	case "chat.new":
		id := fmt.Sprintf("c-%d", time.Now().UnixNano())
		c := store.Chat{ID: id, Title: "New chat", Updated: time.Now()}
		s.St.SaveChat(c)
		return map[string]any{"id": id}
	case "composer.get":
		comp := fillComposer(s.St.Settings.Composer)
		perChat := false
		for _, c := range s.St.Chats {
			if c.ID == str(in, "id") && c.Composer != nil {
				comp, perChat = fillComposer(*c.Composer), true
			}
		}
		return map[string]any{"ok": true, "composer": comp, "perChat": perChat, "tiers": Tiers, "default": fillComposer(s.St.Settings.Composer)}
	case "composer.set":
		comp := fillComposer(store.Composer{Tier: str(in, "tier"), Length: str(in, "length"), Quick: in["quick"] == true})
		if in["global"] == true {
			st := s.St.Settings
			st.Composer = comp
			s.St.SetSettings(st)
		}
		for i := range s.St.Chats {
			if s.St.Chats[i].ID == str(in, "id") {
				c := s.St.Chats[i]
				c.Composer = &comp
				s.St.SaveChat(c)
			}
		}
		return map[string]any{"ok": true, "composer": comp}
	case "chat.get":
		id, _ := in["id"].(string)
		for _, c := range s.St.Chats {
			if c.ID == id {
				return map[string]any{"id": c.ID, "title": c.Title, "messages": c.Messages, "kind": c.Kind, "agentID": c.AgentID, "members": c.Members}
			}
		}
		return map[string]any{"messages": []any{}}
	case "chat.send":
		return s.chatSend(in)
	case "agent.chat":
		return s.agentChat(str(in, "agent"))
	case "party.new":
		ms := []string{}
		if a, ok := in["members"].([]any); ok {
			for _, x := range a {
				if v, ok := x.(string); ok && v != "" {
					ms = append(ms, v)
				}
			}
		}
		return s.partyNew(str(in, "title"), ms)
	case "chat.delete":
		s.St.DeleteChat(str(in, "id"))
		return map[string]any{"ok": true}
	case "agent.save":
		return s.agentSave(in)
	case "agent.testVortex":
		return s.testVortex()
	case "integration":
		return s.integration(str(in, "id"))
	case "plugin.make":
		return s.pluginMake(str(in, "description"))
	case "plugin.upload":
		return s.pluginUpload(str(in, "json"))
	case "plugin.mine":
		return s.pluginReq("GET", "?mine=1", nil, true)
	case "plugin.update":
		return s.pluginReq("PUT", "/"+str(in, "id"), in["patch"], true)
	case "plugin.delete":
		return s.pluginReq("DELETE", "/"+str(in, "id"), nil, true)
	case "plugin.install":
		return s.pluginInstall(str(in, "id"))
	case "plugin.installed":
		return s.pluginInstalled()
	case "plugin.icon":
		return s.pluginIcon(str(in, "prompt"))
	case "plugin.store":
		return s.pluginStore()
	case "media.submit":
		return s.mediaSubmit(in)
	case "media.job":
		return s.mediaJob(str(in, "id"))
	case "media.jobs":
		return s.mediaJobs()
	case "run.start":
		return s.startRun(str(in, "agentID"), str(in, "task"), str(in, "chatID"))
	case "run.list":
		return map[string]any{"runs": listRuns()}
	case "run.approve":
		return s.approve(str(in, "runID"), in["allow"] == true)
	case "run.stop":
		return s.stopRun(str(in, "runID"))
	case "activity.search":
		return map[string]any{"events": s.Act.Search(s.activityQuery(in))}
	case "activity.stats":
		return map[string]any{"agents": s.Act.Stats(), "runs": listRuns()}
	case "activity.export":
		return s.activityExport(in)
	case "notif.list":
		return s.gw("GET", "/notifications", nil)
	case "notif.read":
		return s.gw("POST", "/notifications/read", in)
	default:
		if strings.HasPrefix(m, "gate.") || strings.HasPrefix(m, "redx.") {
			return s.redx(m, in)
		}
		return map[string]any{"ok": false, "error": "unknown method " + m}
	}
}

func chatSummaries(cs []store.Chat) []map[string]any {
	out := make([]map[string]any, 0, len(cs))
	for _, c := range cs {
		out = append(out, map[string]any{"id": c.ID, "title": c.Title, "kind": c.Kind, "agentID": c.AgentID, "members": c.Members})
	}
	return out
}

func (s *Server) listModels() ([]string, bool) {
	key := keyring.Get("vortex-api-key")
	req, _ := http.NewRequest("GET", s.St.Settings.BaseURL+"/models", nil)
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	cli := &http.Client{Timeout: 8 * time.Second}
	res, err := cli.Do(req)
	if err != nil {
		return []string{"vortex"}, false
	}
	defer res.Body.Close()
	var body struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	json.NewDecoder(res.Body).Decode(&body)
	ids := []string{}
	for _, d := range body.Data {
		ids = append(ids, d.ID)
	}
	if len(ids) == 0 {
		ids = []string{"vortex"}
	}
	return ids, res.StatusCode == 200
}

func (s *Server) chatSend(in map[string]any) map[string]any {
	id := str(in, "id")
	text := str(in, "text")
	model := str(in, "model")
	if model == "" {
		model = "vortex"
	}
	agentID := str(in, "agent")
	base, key := s.resolveEndpoint(agentID)
	var c *store.Chat
	for i := range s.St.Chats {
		if s.St.Chats[i].ID == id {
			c = &s.St.Chats[i]
			break
		}
	}
	if c == nil {
		return map[string]any{"error": "chat not found"}
	}
	c.Messages = append(c.Messages, store.Msg{Role: "user", Content: text})
	if c.Title == "New chat" && len(text) > 0 {
		t := text
		if len(t) > 40 {
			t = t[:40] + "…"
		}
		c.Title = t
	}
	comp := fillComposer(s.St.Settings.Composer)
	if c.Composer != nil {
		comp = fillComposer(*c.Composer)
	}
	if c.Kind == "agent" && strings.HasPrefix(strings.TrimSpace(text), "/run ") {
		s.St.SaveChat(*c)
		r := s.startRun(c.AgentID, strings.TrimPrefix(strings.TrimSpace(text), "/run "), c.ID)
		note := "Working on it. Follow along (and Allow/Deny actions) in Activity."
		if r["ok"] != true {
			note = fmt.Sprint(r["message"])
		}
		c.Messages = append(c.Messages, msgOf(s.memberFor(c.AgentID).Name, note))
		s.St.SaveChat(*c)
		return map[string]any{"reply": note, "replies": []map[string]string{{"name": s.memberFor(c.AgentID).Name, "content": note}}, "run": r["run"]}
	}
	if c.Kind == "agent" || c.Kind == "party" {
		return s.groupSend(c, comp)
	}
	if strings.HasPrefix(model, "vortex") && in["modelExplicit"] != true {
		model = comp.Tier
	}
	if comp.Quick && strings.HasPrefix(model, "vortex") {
		model = "vortex-mini"
	}
	maxTok, hint := lengthParams(comp)
	msgs := []map[string]string{}
	if hint != "" {
		msgs = append(msgs, map[string]string{"role": "system", "content": hint})
	}
	for _, m := range c.Messages {
		msgs = append(msgs, map[string]string{"role": m.Role, "content": m.Content})
	}
	body := map[string]any{"model": model, "messages": msgs, "temperature": 0.4, "max_tokens": maxTok}
	raw, _ := json.Marshal(body)
	cli := &http.Client{Timeout: 600 * time.Second}
	var res *http.Response
	for attempt := 0; ; attempt++ {
		req, _ := http.NewRequest("POST", base+"/chat/completions", bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		r, err := cli.Do(req)
		if err != nil {
			return map[string]any{"error": err.Error()}
		}
		if r.StatusCode < 500 {
			res = r
			break
		}
		r.Body.Close()
		if attempt >= 2 { // the server is loading/unloading models
			return map[string]any{"error": "Vortex is loading this model on the server (retried 3×). Please send again in a few seconds."}
		}
		time.Sleep(time.Duration(6*(attempt+1)) * time.Second)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var parsed map[string]any
	json.Unmarshal(b, &parsed)
	reply := ""
	if ch, ok := parsed["choices"].([]any); ok && len(ch) > 0 {
		if m, ok := ch[0].(map[string]any); ok {
			if msg, ok := m["message"].(map[string]any); ok {
				reply, _ = msg["content"].(string)
			}
		}
	}
	if reply == "" {
		reply = fmt.Sprintf("(HTTP %d)", res.StatusCode)
	}
	c.Messages = append(c.Messages, store.Msg{Role: "assistant", Content: reply})
	c.Updated = time.Now()
	s.St.SaveChat(*c)
	return map[string]any{"reply": reply}
}

func (s *Server) resolveEndpoint(agentID string) (base, key string) {
	base = s.St.Settings.BaseURL
	key = keyring.Get("vortex-api-key")
	for _, a := range s.St.Agents {
		if a.ID != agentID {
			continue
		}
		if a.Provider == "vortex" {
			return base, key
		}
		if a.BaseURL != "" {
			base = strings.TrimRight(a.BaseURL, "/")
			if !strings.HasSuffix(base, "/v1") && !strings.Contains(base, "/v1") {
				base += "/v1"
			}
		} else {
			switch a.Provider {
			case "openai":
				base = "https://api.openai.com/v1"
			case "anthropic":
				base = "https://api.anthropic.com/v1"
			case "google":
				base = "https://generativelanguage.googleapis.com/v1beta/openai"
			case "xai":
				base = "https://api.x.ai/v1"
			case "openrouter":
				base = "https://openrouter.ai/api/v1"
			case "ollama":
				base = "http://127.0.0.1:11434/v1"
				// custom / openai-compatible: use BaseURL from agent
			}
		}
		if k := keyring.Get("agent-key-" + a.ID); k != "" {
			key = k
		}
		return base, key
	}
	return base, key
}

func (s *Server) agentSave(in map[string]any) map[string]any {
	name := str(in, "name")
	if name == "" {
		return map[string]any{"ok": false, "message": "Name required"}
	}
	id := fmt.Sprintf("agent-%d", time.Now().UnixNano()%1e12)
	a := store.Agent{
		ID: id, Name: name, Provider: str(in, "provider"), Model: str(in, "model"),
		BaseURL: str(in, "baseURL"), ToolsOn: true, PCControlOn: true,
		SystemPrompt: "You are a Vortex agent. Use tools carefully; ask Allow/Deny for risky PC actions.",
		Created:      time.Now(), Updated: time.Now(),
	}
	if a.Provider == "" {
		a.Provider = "vortex"
	}
	if a.Model == "" {
		a.Model = "vortex-mini" // new agents default to the fast tier
	}
	if k := str(in, "apiKey"); k != "" && a.Provider != "vortex" {
		_ = keyring.Set("agent-key-"+a.ID, k)
	}
	s.St.SaveAgent(a)
	return map[string]any{"ok": true, "message": "Saved " + a.Name + ". Key in OS credential store (never printed)."}
}

func (s *Server) testVortex() map[string]any {
	key := keyring.Get("vortex-api-key")
	body := map[string]any{
		"model": "vortex",
		"messages": []map[string]string{
			{"role": "user", "content": "Reply with exactly: VORTEX_AGENT_OK"},
		},
		"max_tokens": 32, "temperature": 0,
	}
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", s.St.Settings.BaseURL+"/chat/completions", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	cli := &http.Client{Timeout: 60 * time.Second}
	res, err := cli.Do(req)
	if err != nil {
		return map[string]any{"ok": false, "message": "E2E failed: " + err.Error()}
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	text := string(b)
	if res.StatusCode == 200 && strings.Contains(text, "VORTEX_AGENT_OK") {
		return map[string]any{"ok": true, "message": "E2E OK: vortex replied VORTEX_AGENT_OK."}
	}
	if res.StatusCode == 200 {
		return map[string]any{"ok": true, "message": "E2E partial: HTTP 200; marker may be paraphrased."}
	}
	return map[string]any{"ok": false, "message": fmt.Sprintf("E2E failed: HTTP %d", res.StatusCode)}
}

func (s *Server) integration(id string) map[string]any {
	home, _ := os.UserHomeDir()
	key := keyring.Get("vortex-api-key")
	base := strings.TrimSuffix(s.St.Settings.BaseURL, "/v1")
	switch id {
	case "omniroute":
		dir := filepath.Join(home, ".config", "omniroute")
		_ = os.MkdirAll(dir, 0700)
		p := filepath.Join(dir, "vortex-provider.json")
		doc := map[string]any{
			"name": "Vortex", "provider": "openai", "base_url": base + "/v1",
			"api_key_env": "VORTEX_API_KEY", "models": []string{"vortex"},
		}
		b, _ := json.MarshalIndent(doc, "", "  ")
		_ = os.WriteFile(p, b, 0600)
		if key != "" {
			_ = os.WriteFile(filepath.Join(dir, ".vortex-key"), []byte(key), 0600)
		}
		return map[string]any{"ok": true, "message": "OmniRoute provider written to " + p}
	case "vscode", "continue":
		p := filepath.Join(home, ".continue", "config.yaml")
		_ = os.MkdirAll(filepath.Dir(p), 0700)
		item := fmt.Sprintf("  # red-xai-vortex begin\n  - name: Vortex\n    provider: openai\n    model: vortex\n    apiBase: %s/v1\n    apiKey: %s\n    roles: [chat, edit, apply]\n  # red-xai-vortex end\n", base, key)
		y := "name: Local Config\nversion: 1.0.0\nschema: v1\nmodels:\n"
		if b, err := os.ReadFile(p); err == nil {
			y = string(b)
			if i := strings.Index(y, "# red-xai-vortex begin"); i >= 0 {
				if j := strings.Index(y[i:], "# red-xai-vortex end"); j >= 0 {
					y = y[:i] + y[i+j+len("# red-xai-vortex end\n"):]
				}
			}
			if !strings.Contains(y, "models:") {
				y += "models:\n"
			}
		}
		_ = os.WriteFile(p, []byte(y+item), 0600)
		return map[string]any{"ok": true, "message": "VS Code / Continue config updated at " + p}
	case "test-omniroute":
		p := filepath.Join(home, ".config", "omniroute", "vortex-provider.json")
		if _, err := os.Stat(p); err != nil {
			return map[string]any{"ok": false, "message": "Provider file missing; Connect first."}
		}
		return map[string]any{"ok": true, "message": "OmniRoute provider present."}
	case "test-vscode":
		p := filepath.Join(home, ".continue", "config.yaml")
		b, err := os.ReadFile(p)
		if err != nil || !strings.Contains(string(b), "red-xai-vortex begin") {
			return map[string]any{"ok": false, "message": "Continue config missing Vortex block."}
		}
		return map[string]any{"ok": true, "message": "Continue config has Vortex entry."}
	default:
		return map[string]any{"ok": false, "message": "Unknown integration"}
	}
}

func str(m map[string]any, k string) string {
	v, _ := m[k].(string)
	return v
}

