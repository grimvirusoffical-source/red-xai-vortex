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
}
type Msg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type Settings struct {
	BaseURL      string `json:"baseURL"`
	ActiveID     string `json:"activeAgent"`
	NoAutoUpdate bool   `json:"noAutoUpdate"`
}

type Store struct {
	mu       sync.Mutex
	Dir      string
	Agents   []Agent
	Chats    []Chat
	Settings Settings
}

func Open() *Store {
	h, _ := os.UserHomeDir()
	d := filepath.Join(h, ".config", "red-xai-vortex")
	_ = os.MkdirAll(d, 0700)
	s := &Store{Dir: d, Settings: Settings{BaseURL: "https://45.77.105.187/v1", ActiveID: "vortex-default"}}
	s.load()
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
