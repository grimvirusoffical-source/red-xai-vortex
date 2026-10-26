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
