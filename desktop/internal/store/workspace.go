package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const WorkspaceVersion = 1
const DefaultMemoryQuota = int64(64 << 20)
const MaxAttachmentBytes = int64(32 << 20)

var ErrMemoryQuotaExceeded = errors.New("memory quota exceeded; remove entries or increase the quota")

// Workspace is additive: legacy chats, agents and settings remain in their original files.
// It only contains user-selected context. No credentials or attachment bytes belong here.
type Workspace struct {
	Version       int            `json:"version"`
	Projects      []Project      `json:"projects"`
	Personalities []Personality  `json:"personalities"`
	Bases         []Base         `json:"bases"`
	Memory        Memory         `json:"memory"`
	Worlds        []World        `json:"worlds"`
	ChatSettings  []ChatSettings `json:"chatSettings"`
	Attachments   []Attachment   `json:"attachments"`
	Proposals     []Proposal     `json:"proposals"`
}
type Project struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	Description   string            `json:"description"`
	Instructions  string            `json:"instructions"`
	ChatIDs       []string          `json:"chatIDs"`
	AttachmentIDs []string          `json:"attachmentIDs"`
	BaseIDs       []string          `json:"baseIDs"`
	PersonalityID string            `json:"personalityID"`
	MemoryEnabled bool              `json:"memoryEnabled"`
	Settings      map[string]string `json:"settings,omitempty"`
	UpdatedAt     time.Time         `json:"updatedAt"`
}
type Personality struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Description  string    `json:"description"`
	Instructions string    `json:"instructions"`
	UpdatedAt    time.Time `json:"updatedAt"`
}
type Source struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Kind         string    `json:"kind"`
	MIMEType     string    `json:"mimeType"`
	Text         string    `json:"text,omitempty"`
	URL          string    `json:"url,omitempty"`
	AttachmentID string    `json:"attachmentID,omitempty"`
	Tags         []string  `json:"tags,omitempty"`
	Bytes        int64     `json:"bytes"`
	UpdatedAt    time.Time `json:"updatedAt"`
}
type BasePermissions struct {
	Read   bool `json:"read"`
	Search bool `json:"search"`
}
type Base struct {
	ID          string          `json:"id"`
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Sources     []Source        `json:"sources"`
	Permissions BasePermissions `json:"permissions"`
	Endpoint    string          `json:"endpoint,omitempty"`
	RemoteID    string          `json:"remoteID,omitempty"`
	Revision    string          `json:"revision,omitempty"`
	Status      string          `json:"status"`
	LastChecked *time.Time      `json:"lastChecked,omitempty"`
	LastError   string          `json:"lastError,omitempty"`
	UpdatedAt   time.Time       `json:"updatedAt"`
	Hosting     *HostingConfig  `json:"hosting,omitempty"`
}
type HostingConfig struct {
	Enabled        bool   `json:"enabled"`
	Listen         string `json:"listen"`
	PublicEndpoint string `json:"publicEndpoint,omitempty"`
	TLSCert        string `json:"tlsCert,omitempty"`
	TLSKey         string `json:"tlsKey,omitempty"`
}
type Proposal struct {
	ID            string    `json:"id"`
	Kind          string    `json:"kind"`
	ChatID        string    `json:"chatID"`
	Scope         string    `json:"scope"`
	ScopeID       string    `json:"scopeID,omitempty"`
	Title         string    `json:"title"`
	Text          string    `json:"text"`
	CreatedAt     time.Time `json:"createdAt"`
	OriginalState string    `json:"originalState,omitempty"`
}
type Memory struct {
	QuotaBytes int64         `json:"quotaBytes"`
	Entries    []MemoryEntry `json:"entries"`
}
type MemoryEntry struct {
	ID            string    `json:"id"`
	Title         string    `json:"title"`
	Text          string    `json:"text"`
	Scope         string    `json:"scope"`
	ScopeID       string    `json:"scopeID,omitempty"`
	AttachmentIDs []string  `json:"attachmentIDs"`
	Tags          []string  `json:"tags,omitempty"`
	CreatedAt     time.Time `json:"createdAt"`
	UpdatedAt     time.Time `json:"updatedAt"`
	Origin        string    `json:"origin,omitempty"`
	ChatID        string    `json:"chatID,omitempty"`
}
type World struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	Description   string    `json:"description"`
	Instructions  string    `json:"instructions"`
	Lore          string    `json:"lore"`
	Characters    string    `json:"characters"`
	WorldState    string    `json:"worldState"`
	MemoryEnabled bool      `json:"memoryEnabled"`
	UpdatedAt     time.Time `json:"updatedAt"`
}
type CodeFile struct {
	Path     string `json:"path"`
	Language string `json:"language,omitempty"`
	Content  string `json:"content"`
}
type CodingContext struct {
	RepoPath string     `json:"repoPath"`
	Branch   string     `json:"branch"`
	Task     string     `json:"task"`
	Diff     string     `json:"diff"`
	Files    []CodeFile `json:"files"`
}
type ChatSettings struct {
	ChatID         string        `json:"chatID"`
	ProjectID      string        `json:"projectID"`
	PersonalityID  string        `json:"personalityID"`
	BaseIDs        []string      `json:"baseIDs"`
	SharedMemory   bool          `json:"sharedMemory"`
	WorldID        string        `json:"worldID"`
	Mode           string        `json:"mode"`
	Coding         CodingContext `json:"coding"`
	MemoryCapture  string        `json:"memoryCapture,omitempty"`
	StateEvolution string        `json:"stateEvolution,omitempty"`
}
type Attachment struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	MIMEType  string    `json:"mimeType"`
	Bytes     int64     `json:"bytes"`
	Text      string    `json:"text,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
}

func NewWorkspace() Workspace {
	return Workspace{Version: WorkspaceVersion, Projects: []Project{}, Personalities: []Personality{}, Bases: []Base{}, Memory: Memory{QuotaBytes: DefaultMemoryQuota, Entries: []MemoryEntry{}}, Worlds: []World{}, ChatSettings: []ChatSettings{}, Attachments: []Attachment{}, Proposals: []Proposal{}}
}
func (w *Workspace) Normalize() {
	if w.Version == 0 {
		w.Version = WorkspaceVersion
	}
	if w.Memory.QuotaBytes == 0 {
		w.Memory.QuotaBytes = DefaultMemoryQuota
	}
	if w.Projects == nil {
		w.Projects = []Project{}
	}
	if w.Personalities == nil {
		w.Personalities = []Personality{}
	}
	if w.Bases == nil {
		w.Bases = []Base{}
	}
	if w.Memory.Entries == nil {
		w.Memory.Entries = []MemoryEntry{}
	}
	if w.Worlds == nil {
		w.Worlds = []World{}
	}
	if w.ChatSettings == nil {
		w.ChatSettings = []ChatSettings{}
	}
	if w.Proposals == nil {
		w.Proposals = []Proposal{}
	}
	if w.Attachments == nil {
		w.Attachments = []Attachment{}
	}
}
func (w Workspace) MemoryUsage() int64 {
	var total int64
	for _, p := range w.Proposals {
		total += int64(len(p.Title) + len(p.Text) + len(p.OriginalState))
	}
	used := map[string]bool{}
	for _, e := range w.Memory.Entries {
		total += int64(len(e.Title) + len(e.Text))
		for _, id := range e.AttachmentIDs {
			used[id] = true
		}
	}
	for _, a := range w.Attachments {
		if used[a.ID] {
			total += a.Bytes + int64(len(a.Text))
		}
	}
	return total
}
func (w Workspace) Validate() error {
	if w.Version != WorkspaceVersion {
		return fmt.Errorf("unsupported workspace version %d", w.Version)
	}
	if w.Memory.QuotaBytes < 1024 || w.Memory.QuotaBytes > 100<<30 {
		return errors.New("memory quota must be between 1 KiB and 100 GiB")
	}
	if len(w.Proposals) > 100 {
		return errors.New("at most 100 pending proposals; review or dismiss older ones")
	}
	for _, c := range w.ChatSettings {
		for _, mode := range []string{c.MemoryCapture, c.StateEvolution} {
			if mode != "" && mode != "off" && mode != "review" && mode != "save" {
				return errors.New("automatic context setting must be off, review or save")
			}
		}
	}
	for _, e := range w.Memory.Entries {
		if e.Scope != "global" && e.Scope != "project" && e.Scope != "world" {
			return errors.New("memory scope must be global, project or world")
		}
		if e.Scope != "global" && e.ScopeID == "" {
			return errors.New("scoped memory requires a project or world ID")
		}
	}
	if w.MemoryUsage() > w.Memory.QuotaBytes {
		return ErrMemoryQuotaExceeded
	}
	return nil
}

// WorkspaceSnapshot returns a deep copy so callers cannot mutate persisted state without validation.
func (s *Store) WorkspaceSnapshot() Workspace {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, _ := json.Marshal(s.Workspace)
	var w Workspace
	_ = json.Unmarshal(b, &w)
	w.Normalize()
	return w
}
func (s *Store) UpdateWorkspace(fn func(*Workspace) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.WorkspaceError != "" {
		return fmt.Errorf("workspace requires recovery: %s", s.WorkspaceError)
	}
	b, _ := json.Marshal(s.Workspace)
	var next Workspace
	if err := json.Unmarshal(b, &next); err != nil {
		return err
	}
	next.Normalize()
	if err := fn(&next); err != nil {
		return err
	}
	if err := next.Validate(); err != nil {
		return err
	}
	if err := writeAtomicJSON(s.path("workspace.json"), next); err != nil {
		return err
	}
	s.Workspace = next
	return nil
}
func (s *Store) loadWorkspace() {
	s.Workspace = NewWorkspace()
	b, err := os.ReadFile(s.path("workspace.json"))
	if os.IsNotExist(err) {
		return
	}
	if err != nil {
		s.WorkspaceError = err.Error()
		return
	}
	var w Workspace
	if err = json.Unmarshal(b, &w); err != nil {
		s.WorkspaceError = "existing workspace.json is unreadable; the original file was preserved"
		return
	}
	w.Normalize()
	if err = w.Validate(); err != nil && !errors.Is(err, ErrMemoryQuotaExceeded) {
		s.WorkspaceError = err.Error()
		return
	}
	s.Workspace = w
}
func writeAtomicJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".workspace-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(tmp, path)
}
func ValidAttachmentID(id string) bool {
	if len(id) < 1 || len(id) > 128 {
		return false
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return false
		}
	}
	return true
}
func (s *Store) PutAttachment(a Attachment, data []byte) error {
	if !ValidAttachmentID(a.ID) {
		return errors.New("invalid attachment ID")
	}
	if int64(len(data)) > MaxAttachmentBytes {
		return errors.New("attachment exceeds 32 MiB limit")
	}
	a.Bytes = int64(len(data))
	dir := s.path("attachments")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	p := filepath.Join(dir, a.ID)
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		return errors.New("attachment already exists")
	}
	if err := os.WriteFile(p, data, 0600); err != nil {
		return err
	}
	if err := s.UpdateWorkspace(func(w *Workspace) error { w.Attachments = append(w.Attachments, a); return nil }); err != nil {
		_ = os.Remove(p)
		return err
	}
	return nil
}
func (s *Store) AttachmentData(id string) ([]byte, error) {
	if !ValidAttachmentID(id) {
		return nil, errors.New("invalid attachment ID")
	}
	return os.ReadFile(filepath.Join(s.path("attachments"), id))
}
func (s *Store) DeleteAttachment(id string) error {
	if !ValidAttachmentID(id) {
		return errors.New("invalid attachment ID")
	}
	if err := s.UpdateWorkspace(func(w *Workspace) error {
		for _, e := range w.Memory.Entries {
			for _, v := range e.AttachmentIDs {
				if v == id {
					return errors.New("attachment is used by memory; remove the reference first")
				}
			}
		}
		for _, p := range w.Projects {
			for _, v := range p.AttachmentIDs {
				if v == id {
					return errors.New("attachment is used by a project")
				}
			}
		}
		for _, b := range w.Bases {
			for _, v := range b.Sources {
				if v.AttachmentID == id {
					return errors.New("attachment is used by a Base")
				}
			}
		}
		out := w.Attachments[:0]
		for _, a := range w.Attachments {
			if a.ID != id {
				out = append(out, a)
			}
		}
		w.Attachments = out
		return nil
	}); err != nil {
		return err
	}
	err := os.Remove(filepath.Join(s.path("attachments"), id))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
func (w Workspace) Search(baseID, query string) []Source {
	words := strings.Fields(strings.ToLower(query))
	out := []Source{}
	for _, b := range w.Bases {
		if baseID != "" && b.ID != baseID {
			continue
		}
		if !b.Permissions.Read || !b.Permissions.Search || b.Status == "revoked" || b.Status == "disconnected" {
			continue
		}
		for _, src := range b.Sources {
			hay := strings.ToLower(src.Name + " " + src.Text + " " + strings.Join(src.Tags, " "))
			match := len(words) == 0
			for _, word := range words {
				if strings.Contains(hay, word) {
					match = true
					break
				}
			}
			if match {
				out = append(out, src)
				if len(out) >= 20 {
					return out
				}
			}
		}
	}
	return out
}
