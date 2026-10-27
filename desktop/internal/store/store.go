package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Agent struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Description  string    `json:"description"`
	Provider     string    `json:"provider"`
	Model        string    `json:"model"`
	BaseURL      string    `json:"baseURL"`
	SystemPrompt string    `json:"systemPrompt"`
	ToolsOn      bool      `json:"toolsOn"`
	PCControlOn  bool      `json:"pcControlOn"`
	Goal         string    `json:"goal,omitempty"`
	ModelMode    string    `json:"modelMode,omitempty"` // single | auto | mix
	ModelPool    []string  `json:"modelPool,omitempty"`
	Permissions  []string  `json:"permissions"` // web, files-read, files-write, shell
	ScheduleS    int       `json:"scheduleSeconds,omitempty"` // 0 manual, 15 nonstop, >=30 periodic
	Nonstop      bool      `json:"nonstop,omitempty"`
	RunOn        string    `json:"runOn,omitempty"` // local or server; cloudpc requires worker
	Running      bool      `json:"running,omitempty"`
	AlwaysAllow  bool      `json:"alwaysAllow,omitempty"` // additional agent opt-in; machine policy still required
	LastRun      time.Time `json:"lastRun,omitempty"`
	Created      time.Time `json:"created"`
	Updated      time.Time `json:"updated"`
}

type Chat struct {
	ID       string    `json:"id"`
	Title    string    `json:"title"`
	Messages []Msg     `json:"messages"`
	Updated  time.Time `json:"updated"`
	Composer *Composer `json:"composer,omitempty"` // per-chat composer settings; nil = global default
	Kind     string    `json:"kind,omitempty"`     // "" (model chat) | "agent" | "party"
	AgentID  string    `json:"agentID,omitempty"`  // agent chats: the agent
	Members  []string  `json:"members,omitempty"`  // party chats: agent IDs (or "model:<id>") that reply in turn
	LeaderID string   `json:"leaderID,omitempty"` // one leader chooses assignments and consolidates results
	WorkspaceID string `json:"groupWorkspaceID,omitempty"` // project-scoped group conversations
	GroupInstructions string `json:"groupInstructions,omitempty"`
}

// Composer holds the chat composer controls: strength tier, reply length and Quick replies.
type Composer struct {
	Tier   string `json:"tier"`   // vortex-mini | vortex-std | vortex-pro | vortex
	Length string `json:"length"` // short | normal | long
	Quick  bool   `json:"quick"`
}
type Msg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
	Name    string `json:"name,omitempty"` // speaker name in agent/party chats
}

type Settings struct {
	BaseURL      string   `json:"baseURL"`
	ActiveID     string   `json:"activeAgent"`
	NoAutoUpdate bool     `json:"noAutoUpdate"`
	Composer     Composer `json:"composer"`   // global default for new chats
	PlainChat    bool     `json:"plainChat"`  // false = Secure chat (Red-SecretsXAI) on
	PhoneChat    bool     `json:"phoneChat"`  // serve the LAN phone chat page
	LinkServer   string   `json:"linkServer"` // RedX Link host:port (default 45.77.105.187:8093)
}

type Store struct {
	pcPolicy       PCControlPolicy
	pcPolicyError  error
	mu             sync.Mutex
	Dir            string
	Agents         []Agent
	Chats          []Chat
	Settings       Settings
	Workspace      Workspace
	WorkspaceError string
}

func Open() *Store {
	d := os.Getenv("VORTEX_DATA_DIR")
	if d == "" {
		h, _ := os.UserHomeDir()
		d = filepath.Join(h, ".config", "red-xai-vortex")
	}
	return OpenAt(d)
}

// OpenAt provides an explicit storage directory for managed installations and
// isolated fixtures without changing the user's home or existing configuration.
func OpenAt(d string) *Store {
	_ = os.MkdirAll(d, 0700)
	s := &Store{Dir: d, Settings: Settings{BaseURL: "https://45.77.105.187/v1", ActiveID: "vortex-default"}}
	s.load()
	s.loadPCPolicy()
	s.loadWorkspace()
	if len(s.Agents) == 0 {
		s.Agents = []Agent{{
			ID: "vortex-default", Name: "Vortex", Provider: "vortex", Model: "vortex",
			SystemPrompt: "You are Vortex, the Red-XAI Vortex assistant: sharp, friendly and direct.",
			ToolsOn:      true, PCControlOn: true, Created: time.Now(), Updated: time.Now(),
		}}
		s.save()
	}
	return s
}

func (s *Store) path(n string) string { return filepath.Join(s.Dir, n) }

func (s *Store) load() {
	_ = readJSON(s.path("agents.json"), &s.Agents)
	_ = readJSON(s.path("chats.json"), &s.Chats)
	_ = readJSON(s.path("settings.json"), &s.Settings)
	if b := s.Settings.BaseURL; b == "" || strings.Contains(b, ":8091") || strings.Contains(b, ":18091") || strings.HasPrefix(b, "http://45.77.105.187") {
		s.Settings.BaseURL = "https://45.77.105.187/v1"
	}
}

func (s *Store) save() {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(s.path("agents.json"), s.Agents)
	writeJSON(s.path("chats.json"), s.Chats)
	writeJSON(s.path("settings.json"), s.Settings)
}

// AgentsSnapshot isolates background schedulers from concurrent UI changes.
func (s *Store) AgentsSnapshot() []Agent {
    s.mu.Lock()
    defer s.mu.Unlock()
    out:=append([]Agent(nil),s.Agents...)
    for i:=range out {
        out[i].Permissions=append([]string(nil),out[i].Permissions...)
        out[i].ModelPool=append([]string(nil),out[i].ModelPool...)
    }
    return out
}

// ClaimAgentDue atomically records a run's next scheduling timestamp only
// while the currently saved version is still due. This prevents a racing
// edit/Stop from scheduling an outdated goal or resetting its permissions.
func (s *Store) AgentIsRunning(id string) bool {
    s.mu.Lock()
    defer s.mu.Unlock()
    for _,a:=range s.Agents {
        if a.ID==id {return a.Running}
    }
    return false
}

func (s *Store) ClaimAgentDue(id string,now time.Time,due func(Agent) bool)(Agent,bool){
    s.mu.Lock()
    defer s.mu.Unlock()
    for i,a:=range s.Agents {
        if a.ID==id && due(a) {
            a.LastRun=now
            s.Agents[i]=a
            writeJSON(s.path("agents.json"),s.Agents)
            return a,true
        }
    }
    return Agent{},false
}

func (s *Store) SaveAgent(a Agent) {
	s.mu.Lock()
	found := false
	for i := range s.Agents {
		if s.Agents[i].ID == a.ID {
			s.Agents[i] = a
			found = true
			break
		}
	}
	if !found {
		s.Agents = append(s.Agents, a)
	}
	s.mu.Unlock()
	s.save()
}

func (s *Store) DeleteAgent(id string) bool {
	s.mu.Lock()
	out := make([]Agent, 0, len(s.Agents))
	found := false
	for _, a := range s.Agents {
		if a.ID == id { found = true; continue }
		out = append(out, a)
	}
	if found { s.Agents = out }
	s.mu.Unlock()
	if found { s.save() }
	return found
}

func (s *Store) SaveChat(c Chat) {
	s.mu.Lock()
	found := false
	for i := range s.Chats {
		if s.Chats[i].ID == c.ID {
			s.Chats[i] = c
			found = true
			break
		}
	}
	if !found {
		s.Chats = append([]Chat{c}, s.Chats...)
	}
	s.mu.Unlock()
	s.save()
}

func (s *Store) DeleteChat(id string) {
	s.mu.Lock()
	out := s.Chats[:0]
	for _, c := range s.Chats {
		if c.ID != id {
			out = append(out, c)
		}
	}
	s.Chats = out
	s.mu.Unlock()
	s.save()
}

func (s *Store) SetSettings(st Settings) {
	s.mu.Lock()
	s.Settings = st
	s.mu.Unlock()
	s.save()
}

func readJSON(p string, v any) error {
	b, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}
func writeJSON(p string, v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	_ = os.WriteFile(p, b, 0600)
}
