package bridge

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func workspaceID(prefix string) string { return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano()) }
func workspaceError(err error) map[string]any {
	return map[string]any{"ok": false, "error": err.Error(), "message": err.Error()}
}
func (s *Server) workspaceResult() map[string]any {
	w := s.St.WorkspaceSnapshot()
	out := map[string]any{"ok": true, "workspace": w, "usageBytes": w.MemoryUsage()}
	if s.St.WorkspaceError != "" {
		out["warning"] = s.St.WorkspaceError
		out["readOnly"] = true
	}
	return out
}
func decodeValue(in map[string]any, out any) error {
	v, ok := in["value"]
	if !ok {
		return errors.New("value required")
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(raw) > 4<<20 {
		return errors.New("workspace value exceeds 4 MiB")
	}
	return json.Unmarshal(raw, out)
}
func upsert[T any](items []T, value T, id func(T) string) []T {
	for i, v := range items {
		if id(v) == id(value) {
			items[i] = value
			return items
		}
	}
	return append(items, value)
}
func removeItem[T any](items []T, id string, key func(T) string) []T {
	out := items[:0]
	for _, item := range items {
		if key(item) != id {
			out = append(out, item)
		}
	}
	return out
}
func boundedField(v string, max int) error {
	if len(v) > max {
		return fmt.Errorf("text exceeds %d bytes", max)
	}
	return nil
}
func (s *Server) workspaceSave(in map[string]any) map[string]any {
	kind := str(in, "kind")
	id := ""
	now := time.Now().UTC()
	err := s.St.UpdateWorkspace(func(w *store.Workspace) error {
		switch kind {
		case "project":
			var p store.Project
			if err := decodeValue(in, &p); err != nil {
				return err
			}
			if strings.TrimSpace(p.Name) == "" {
				return errors.New("project name required")
			}
			if p.ID == "" {
				p.ID = workspaceID("project")
			}
			p.UpdatedAt = now
			id = p.ID
			w.Projects = upsert(w.Projects, p, func(p store.Project) string { return p.ID })
			selected := map[string]bool{}
			for _, chatID := range p.ChatIDs {
				found := false
				for _, chat := range s.St.Chats {
					if chat.ID == chatID {
						found = true
						break
					}
				}
				if !found {
					return errors.New("project contains an unknown chat")
				}
				selected[chatID] = true
			}
			for i := range w.ChatSettings {
				if w.ChatSettings[i].ProjectID == p.ID && !selected[w.ChatSettings[i].ChatID] {
					w.ChatSettings[i].ProjectID = ""
				}
			}
			for chatID := range selected {
				found := false
				for i := range w.ChatSettings {
					if w.ChatSettings[i].ChatID == chatID {
						w.ChatSettings[i].ProjectID = p.ID
						found = true
						break
					}
				}
				if !found {
					w.ChatSettings = append(w.ChatSettings, store.ChatSettings{ChatID: chatID, ProjectID: p.ID, Mode: "chat", BaseIDs: []string{}})
				}
				for i := range w.Projects {
					if w.Projects[i].ID != p.ID {
						w.Projects[i].ChatIDs = removeString(w.Projects[i].ChatIDs, chatID)
					}
				}
			}
		case "personality":
			var p store.Personality
			if err := decodeValue(in, &p); err != nil {
				return err
			}
			if strings.TrimSpace(p.Name) == "" {
				return errors.New("personality name required")
			}
			if p.ID == "" {
				p.ID = workspaceID("personality")
			}
			if err := boundedField(p.Instructions, 65536); err != nil {
				return err
			}
			p.UpdatedAt = now
			id = p.ID
			w.Personalities = upsert(w.Personalities, p, func(p store.Personality) string { return p.ID })
		case "base":
			var b store.Base
			if err := decodeValue(in, &b); err != nil {
				return err
			}
			if strings.TrimSpace(b.Name) == "" {
				return errors.New("Base name required")
			}
			if b.ID == "" {
				b.ID = workspaceID("base")
			}
			if !store.ValidAttachmentID(b.ID) {
				return errors.New("invalid Base ID")
			}
			if b.Sources == nil {
				b.Sources = []store.Source{}
			}
			// Connections and remote source caches may only be changed through authenticated actions.
			existing := false
			for _, old := range w.Bases {
				if old.ID == b.ID {
					existing = true
					b.Endpoint = old.Endpoint
					b.RemoteID = old.RemoteID
					b.Status = old.Status
					b.LastChecked = old.LastChecked
					b.LastError = old.LastError
					b.Revision = old.Revision
					if old.Endpoint != "" {
						b.Sources = old.Sources
					}
					break
				}
			}
			if !existing {
				b.Endpoint = ""
				b.RemoteID = ""
				b.Status = "local"
				if value, ok := in["value"].(map[string]any); ok {
					if _, provided := value["permissions"]; !provided {
						b.Permissions = store.BasePermissions{Read: true, Search: true}
					}
				}
			}
			for i := range b.Sources {
				if b.Sources[i].ID == "" {
					b.Sources[i].ID = workspaceID("source")
				}
				if err := validateSource(b.Sources[i]); err != nil {
					return err
				}
			}
			b.UpdatedAt = now
			id = b.ID
			w.Bases = upsert(w.Bases, b, func(b store.Base) string { return b.ID })
		case "memory":
			var e store.MemoryEntry
			if err := decodeValue(in, &e); err != nil {
				return err
			}
			if e.ID == "" {
				e.ID = workspaceID("memory")
			}
			if e.Scope == "" {
				e.Scope = "global"
			}
			if strings.TrimSpace(e.Title+e.Text) == "" && len(e.AttachmentIDs) == 0 {
				return errors.New("memory needs text or an attachment")
			}
			if e.CreatedAt.IsZero() {
				e.CreatedAt = now
			}
			e.UpdatedAt = now
			id = e.ID
			for _, a := range e.AttachmentIDs {
				if !hasAttachment(*w, a) {
					return errors.New("memory attachment not found")
				}
			}
			if e.Scope == "world" && !hasWorld(*w, e.ScopeID) {
				return errors.New("world memory requires an existing world")
			}
			if e.Scope == "project" && !hasProject(*w, e.ScopeID) {
				return errors.New("project memory requires an existing project")
			}
			w.Memory.Entries = upsert(w.Memory.Entries, e, func(e store.MemoryEntry) string { return e.ID })
		case "world":
			var v store.World
			if err := decodeValue(in, &v); err != nil {
				return err
			}
			if strings.TrimSpace(v.Name) == "" {
				return errors.New("world name required")
			}
			if v.ID == "" {
				v.ID = workspaceID("world")
			}
			v.UpdatedAt = now
			id = v.ID
			w.Worlds = upsert(w.Worlds, v, func(v store.World) string { return v.ID })
		case "chatSettings":
			var c store.ChatSettings
			if err := decodeValue(in, &c); err != nil {
				return err
			}
			if c.ChatID == "" {
				return errors.New("chat ID required")
			}
			found := false
			for _, chat := range s.St.Chats {
				if chat.ID == c.ChatID {
					found = true
				}
			}
			if !found {
				return errors.New("chat not found")
			}
			if c.Mode == "" {
				c.Mode = "chat"
			}
			if c.Mode != "chat" && c.Mode != "code" && c.Mode != "roleplay" {
				return errors.New("unknown chat mode")
			}
			if c.ProjectID != "" && !hasProject(*w, c.ProjectID) {
				return errors.New("project not found")
			}
			if c.WorldID != "" && !hasWorld(*w, c.WorldID) {
				return errors.New("world not found")
			}
			if err := validateCoding(c.Coding); err != nil {
				return err
			}
			id = c.ChatID
			w.ChatSettings = upsert(w.ChatSettings, c, func(c store.ChatSettings) string { return c.ChatID })
			for i := range w.Projects {
				p := &w.Projects[i]
				p.ChatIDs = removeString(p.ChatIDs, c.ChatID)
				if p.ID == c.ProjectID {
					p.ChatIDs = append(p.ChatIDs, c.ChatID)
				}
			}
		case "memorySettings":
			var m struct {
				QuotaBytes int64 `json:"quotaBytes"`
			}
			if err := decodeValue(in, &m); err != nil {
				return err
			}
			w.Memory.QuotaBytes = m.QuotaBytes
		default:
			return errors.New("unknown workspace kind")
		}
		return nil
	})
	if err != nil {
		return workspaceError(err)
	}
	out := s.workspaceResult()
	out["id"] = id
	return out
}
func removeString(a []string, v string) []string {
	out := a[:0]
	for _, x := range a {
		if x != v {
			out = append(out, x)
		}
	}
	return out
}
func hasAttachment(w store.Workspace, id string) bool {
	for _, a := range w.Attachments {
		if a.ID == id {
			return true
		}
	}
	return false
}
func hasWorld(w store.Workspace, id string) bool {
	for _, v := range w.Worlds {
		if v.ID == id {
			return true
		}
	}
	return false
}
func hasProject(w store.Workspace, id string) bool {
	for _, v := range w.Projects {
		if v.ID == id {
			return true
		}
	}
	return false
}
func (s *Server) workspaceDelete(in map[string]any) map[string]any {
	kind, id := str(in, "kind"), str(in, "id")
	if id == "" {
		return workspaceError(errors.New("ID required"))
	}
	if kind == "base" && !store.ValidAttachmentID(id) {
		return workspaceError(errors.New("valid Base ID required"))
	}
	err := s.St.UpdateWorkspace(func(w *store.Workspace) error {
		switch kind {
		case "project":
			w.Projects = removeItem(w.Projects, id, func(v store.Project) string { return v.ID })
			for i := range w.ChatSettings {
				if w.ChatSettings[i].ProjectID == id {
					w.ChatSettings[i].ProjectID = ""
				}
			}
		case "personality":
			w.Personalities = removeItem(w.Personalities, id, func(v store.Personality) string { return v.ID })
			for i := range w.ChatSettings {
				if w.ChatSettings[i].PersonalityID == id {
					w.ChatSettings[i].PersonalityID = ""
				}
			}
			for i := range w.Projects {
				if w.Projects[i].PersonalityID == id {
					w.Projects[i].PersonalityID = ""
				}
			}
		case "base":
			w.Bases = removeItem(w.Bases, id, func(v store.Base) string { return v.ID })
			for i := range w.ChatSettings {
				w.ChatSettings[i].BaseIDs = removeString(w.ChatSettings[i].BaseIDs, id)
			}
			for i := range w.Projects {
				w.Projects[i].BaseIDs = removeString(w.Projects[i].BaseIDs, id)
			}
		case "memory":
			w.Memory.Entries = removeItem(w.Memory.Entries, id, func(v store.MemoryEntry) string { return v.ID })
		case "world":
			w.Worlds = removeItem(w.Worlds, id, func(v store.World) string { return v.ID })
			for i := range w.ChatSettings {
				if w.ChatSettings[i].WorldID == id {
					w.ChatSettings[i].WorldID = ""
				}
			}
		default:
			return errors.New("unknown workspace kind")
		}
		return nil
	})
	if err != nil {
		return workspaceError(err)
	}
	if kind == "base" {
		if err = keyring.Set("base-token-"+id, ""); err != nil {
			return workspaceError(err)
		}
	}
	return s.workspaceResult()
}
func validateSource(src store.Source) error {
	if strings.TrimSpace(src.Name) == "" {
		return errors.New("source name required")
	}
	if len(src.Text) > 1<<20 {
		return errors.New("source text exceeds 1 MiB")
	}
	if src.Bytes < 0 {
		return errors.New("source bytes cannot be negative")
	}
	if src.URL != "" {
		u, err := url.Parse(src.URL)
		if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil {
			return errors.New("source URL must be an HTTP(S) document URL without credentials")
		}
		for key := range u.Query() {
			k := strings.ToLower(key)
			if strings.Contains(k, "token") || strings.Contains(k, "secret") || strings.Contains(k, "password") || strings.Contains(k, "signature") || k == "key" || k == "api_key" || k == "apikey" || k == "auth" {
				return errors.New("source URLs must not contain access credentials; import document text instead")
			}
		}
	}
	return nil
}
func (s *Server) workspaceAction(in map[string]any) map[string]any {
	action := str(in, "action")
	switch action {
	case "base.connect", "base.health", "base.disconnect", "base.revoke":
		return s.workspaceBaseAction(action, in)
	case "base.search":
		w := s.St.WorkspaceSnapshot()
		if id := str(in, "id"); id != "" {
			for _, b := range w.Bases {
				if b.ID == id && b.Endpoint != "" {
					return s.workspaceRemoteSearch(b, str(in, "query"))
				}
			}
		}
		return map[string]any{"ok": true, "sources": w.Search(str(in, "id"), str(in, "query"))}
	case "personality.export":
		for _, p := range s.St.WorkspaceSnapshot().Personalities {
			if p.ID == str(in, "id") {
				raw, _ := json.MarshalIndent(map[string]any{"format": "vortex-personality", "version": 1, "personality": p}, "", "  ")
				return map[string]any{"ok": true, "json": string(raw)}
			}
		}
		return workspaceError(errors.New("personality not found"))
	case "personality.import":
		raw := str(in, "json")
		if len(raw) > 128<<10 {
			return workspaceError(errors.New("personality file exceeds 128 KiB"))
		}
		var wrapper struct {
			Format      string            `json:"format"`
			Version     int               `json:"version"`
			Personality store.Personality `json:"personality"`
		}
		if err := json.Unmarshal([]byte(raw), &wrapper); err != nil {
			return workspaceError(errors.New("invalid personality JSON"))
		}
		p := wrapper.Personality
		if wrapper.Format == "" {
			if err := json.Unmarshal([]byte(raw), &p); err != nil {
				return workspaceError(err)
			}
		} else if wrapper.Format != "vortex-personality" || wrapper.Version != 1 {
			return workspaceError(errors.New("unsupported personality format"))
		}
		p.ID = ""
		return s.workspaceSave(map[string]any{"kind": "personality", "value": p})
	case "attachment.add":
		data, err := base64.StdEncoding.DecodeString(str(in, "dataBase64"))
		if err != nil {
			return workspaceError(errors.New("invalid attachment encoding"))
		}
		a := store.Attachment{ID: workspaceID("attachment"), Name: filepath.Base(str(in, "name")), MIMEType: str(in, "mimeType"), Bytes: int64(len(data)), CreatedAt: time.Now().UTC()}
		if a.Name == "" || a.Name == "." {
			return workspaceError(errors.New("attachment filename required"))
		}
		if a.MIMEType == "" {
			a.MIMEType = "application/octet-stream"
		}
		if strings.HasPrefix(a.MIMEType, "text/") && utf8.Valid(data) {
			a.Text = string(data)
			if len(a.Text) > 64<<10 {
				a.Text = string(data[:64<<10])
			}
		}
		if err = s.St.PutAttachment(a, data); err != nil {
			return workspaceError(err)
		}
		out := s.workspaceResult()
		out["attachment"] = a
		return out
	case "attachment.get":
		id := str(in, "id")
		for _, a := range s.St.WorkspaceSnapshot().Attachments {
			if a.ID == id {
				data, err := s.St.AttachmentData(id)
				if err != nil {
					return workspaceError(errors.New("attachment file unavailable"))
				}
				return map[string]any{"ok": true, "attachment": a, "dataBase64": base64.StdEncoding.EncodeToString(data)}
			}
		}
		return workspaceError(errors.New("attachment not found"))
	case "attachment.delete":
		if err := s.St.DeleteAttachment(str(in, "id")); err != nil {
			return workspaceError(err)
		}
		return s.workspaceResult()
	case "source.import":
		raw, _ := json.Marshal(in["source"])
		var src store.Source
		if err := json.Unmarshal(raw, &src); err != nil {
			return workspaceError(err)
		}
		if src.ID == "" {
			src.ID = workspaceID("source")
		}
		src.UpdatedAt = time.Now().UTC()
		if src.Kind == "" {
			src.Kind = "text"
		}
		if src.Bytes == 0 {
			src.Bytes = int64(len(src.Text))
		}
		if err := validateSource(src); err != nil {
			return workspaceError(err)
		}
		err := s.St.UpdateWorkspace(func(w *store.Workspace) error {
			for i := range w.Bases {
				b := &w.Bases[i]
				if b.ID == str(in, "baseID") {
					if b.Endpoint != "" {
						return errors.New("edit a remotely hosted Base on its host")
					}
					if src.AttachmentID != "" && !hasAttachment(*w, src.AttachmentID) {
						return errors.New("source attachment not found")
					}
					b.Sources = upsert(b.Sources, src, func(v store.Source) string { return v.ID })
					b.UpdatedAt = time.Now().UTC()
					return nil
				}
			}
			return errors.New("Base not found")
		})
		if err != nil {
			return workspaceError(err)
		}
		out := s.workspaceResult()
		out["source"] = src
		return out
	case "coding.context":
		context := s.workspaceContext(str(in, "chatID"), str(in, "query"))
		return map[string]any{"ok": true, "context": context, "characters": len(context), "capabilities": map[string]any{"text": true, "attachments": "metadata and text extracts; binary media is not transcribed automatically", "repoFiles": "explicit selected files only"}}
	case "coding.inspect":
		return s.workspaceInspect(in)
	default:
		return workspaceError(errors.New("unknown workspace action"))
	}
}

// JSON plus an exact origin check prevents a visited site from changing local
// workspace state or selecting local repository files through cross-site requests.
func workspaceRequestAllowed(r *http.Request) bool {
	if r.Method != http.MethodPost {
		return false
	}
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || contentType != "application/json" {
		return false
	}
	host := r.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	ip := net.ParseIP(host)
	if !strings.EqualFold(host, "localhost") && (ip == nil || !ip.IsLoopback()) {
		return false
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site == "cross-site" {
		return false
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		u, err := url.Parse(origin)
		if err != nil || u.Scheme != "http" || u.Host != r.Host {
			return false
		}
	}
	return true
}
