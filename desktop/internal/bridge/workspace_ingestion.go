package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/ingest"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type sourceImport struct {
	BaseID       string        `json:"baseID"`
	SourceID     string        `json:"sourceID"`
	RefreshOnUse bool          `json:"refreshOnUse"`
	Result       ingest.Result `json:"result"`
	LastError    string        `json:"lastError,omitempty"`
}
type ingestionState struct {
	WhisperModel string                   `json:"whisperModel,omitempty"`
	Documents    []sourceImport           `json:"documents"`
	Attachments  map[string]ingest.Result `json:"attachments"`
}

var ingestionMu sync.Mutex

func (s *Server) readIngestion() ingestionState {
	ingestionMu.Lock()
	defer ingestionMu.Unlock()
	return s.readIngestionLocked()
}
func (s *Server) readIngestionLocked() ingestionState {
	var state ingestionState
	data, _ := os.ReadFile(filepath.Join(s.St.Dir, "ingestion.json"))
	_ = json.Unmarshal(data, &state)
	if state.Attachments == nil {
		state.Attachments = map[string]ingest.Result{}
	}
	if state.Documents == nil {
		state.Documents = []sourceImport{}
	}
	return state
}
func (s *Server) updateIngestion(change func(*ingestionState)) error {
	ingestionMu.Lock()
	defer ingestionMu.Unlock()
	state := s.readIngestionLocked()
	change(&state)
	data, e := json.MarshalIndent(state, "", "  ")
	if e != nil {
		return e
	}
	f, e := os.CreateTemp(s.St.Dir, ".ingestion-*")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(data)
	}
	closeError := f.Close()
	if e == nil {
		e = closeError
	}
	if e != nil {
		return e
	}
	return os.Rename(name, filepath.Join(s.St.Dir, "ingestion.json"))
}
func (s *Server) workspaceIngestionAction(in map[string]any) map[string]any {
	s.cleanupDocumentSubscriptions()
	switch str(in, "action") {
	case "ingestion.status":
		state := s.readIngestion()
		return map[string]any{"ok": true, "tools": ingest.Detect(state.WhisperModel), "documents": state.Documents, "extractions": state.Attachments, "limits": map[string]any{"fileBytes": ingest.MaxInput, "textBytes": ingest.MaxText, "audioSeconds": 600, "videoFrames": 10}}
	case "ingestion.configure":
		model := strings.TrimSpace(str(in, "whisperModel"))
		if model != "" {
			info, e := os.Stat(model)
			if e != nil || !info.Mode().IsRegular() || !filepath.IsAbs(model) {
				return workspaceError(errors.New("choose an existing absolute path to a local Whisper model file"))
			}
		}
		if e := s.updateIngestion(func(state *ingestionState) { state.WhisperModel = model }); e != nil {
			return workspaceError(e)
		}
		return s.workspaceIngestionAction(map[string]any{"action": "ingestion.status"})
	case "source.fetch", "source.refresh":
		return s.fetchDocumentSource(in)
	case "source.disconnect":
		id := str(in, "sourceID")
		if !store.ValidAttachmentID(id) {
			return workspaceError(errors.New("valid source ID required"))
		}
		if e := keyring.Set("document-token-"+id, ""); e != nil {
			return workspaceError(errors.New("document credential could not be removed"))
		}
		if e := s.updateIngestion(func(state *ingestionState) {
			for i := range state.Documents {
				if state.Documents[i].SourceID == id {
					state.Documents[i].RefreshOnUse = false
					state.Documents[i].Result.Status = "snapshot"
					state.Documents[i].LastError = ""
				}
			}
		}); e != nil {
			return workspaceError(e)
		}
		return s.workspaceIngestionAction(map[string]any{"action": "ingestion.status"})
	case "attachment.extract":
		return s.extractWorkspaceAttachment(in)
	}
	return workspaceError(errors.New("unsupported ingestion action"))
}

func (s *Server) cleanupDocumentSubscriptions() {
	available := map[string]bool{}
	for _, base := range s.St.WorkspaceSnapshot().Bases {
		for _, source := range base.Sources {
			available[source.ID] = true
		}
	}
	state := s.readIngestion()
	removed := false
	for _, document := range state.Documents {
		if !available[document.SourceID] {
			_ = keyring.Set("document-token-"+document.SourceID, "")
			removed = true
		}
	}
	if removed {
		_ = s.updateIngestion(func(state *ingestionState) {
			documents := []sourceImport{}
			for _, document := range state.Documents {
				if available[document.SourceID] {
					documents = append(documents, document)
				}
			}
			state.Documents = documents
		})
	}
}

func (s *Server) filterUnavailableDocuments(w *store.Workspace) {
	unavailable := map[string]bool{}
	for _, document := range s.readIngestion().Documents {
		if document.RefreshOnUse && document.Result.Status == "unavailable" {
			unavailable[document.SourceID] = true
		}
	}
	for i := range w.Bases {
		sources := w.Bases[i].Sources[:0]
		for _, source := range w.Bases[i].Sources {
			if !unavailable[source.ID] {
				sources = append(sources, source)
			}
		}
		w.Bases[i].Sources = sources
	}
}
func (s *Server) fetchDocumentSource(in map[string]any) map[string]any {
	baseID := str(in, "baseID")
	sourceID := str(in, "sourceID")
	var existing *store.Source
	found := false
	for _, base := range s.St.WorkspaceSnapshot().Bases {
		if base.ID == baseID {
			if base.Endpoint != "" {
				return workspaceError(errors.New("import remotely hosted documents on their owner host"))
			}
			found = true
			for _, src := range base.Sources {
				if src.ID == sourceID {
					copy := src
					existing = &copy
				}
			}
			break
		}
	}
	if !found {
		return workspaceError(errors.New("local Base not found"))
	}
	refresh := str(in, "action") == "source.refresh"
	raw := str(in, "url")
	name := strings.TrimSpace(str(in, "name"))
	if refresh {
		if existing == nil || existing.URL == "" {
			return workspaceError(errors.New("refresh requires an existing linked document"))
		}
		raw = existing.URL
		name = existing.Name
	}
	if sourceID == "" {
		sourceID = workspaceID("source")
	}
	token := strings.TrimSpace(str(in, "accessToken"))
	if token == "" {
		token = keyring.Get("document-token-" + sourceID)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	result, e := ingest.Fetch(ctx, raw, token)
	if e != nil {
		_ = s.updateIngestion(func(state *ingestionState) {
			for i := range state.Documents {
				if state.Documents[i].SourceID == sourceID {
					state.Documents[i].LastError = e.Error()
					state.Documents[i].Result.Status = "unavailable"
					state.Documents[i].Result.CheckedAt = time.Now().UTC()
				}
			}
		})
		s.syncStartedHosts()
		return workspaceError(e)
	}
	if name == "" {
		name = "Connected document"
	}
	source := store.Source{ID: sourceID, Name: name, Kind: "document", MIMEType: "text/plain", Text: result.Text, URL: result.URL, Bytes: result.Bytes, UpdatedAt: time.Now().UTC()}
	if e = validateSource(source); e != nil {
		return workspaceError(e)
	}
	e = s.St.UpdateWorkspace(func(w *store.Workspace) error {
		for i := range w.Bases {
			if w.Bases[i].ID == baseID && w.Bases[i].Endpoint == "" {
				w.Bases[i].Sources = upsert(w.Bases[i].Sources, source, func(v store.Source) string { return v.ID })
				w.Bases[i].UpdatedAt = time.Now().UTC()
				return nil
			}
		}
		return errors.New("Base no longer available")
	})
	if e != nil {
		return workspaceError(e)
	}
	if token != "" {
		if e = keyring.Set("document-token-"+sourceID, token); e != nil {
			return workspaceError(errors.New("document imported, but its refresh credential could not be saved"))
		}
	}
	auto, _ := in["refreshOnUse"].(bool)
	if refresh {
		for _, record := range s.readIngestion().Documents {
			if record.SourceID == sourceID {
				auto = record.RefreshOnUse
			}
		}
	}
	if e = s.updateIngestion(func(state *ingestionState) {
		next := sourceImport{BaseID: baseID, SourceID: sourceID, RefreshOnUse: auto, Result: result}
		found := false
		for i := range state.Documents {
			if state.Documents[i].SourceID == sourceID {
				state.Documents[i] = next
				found = true
			}
		}
		if !found {
			state.Documents = append(state.Documents, next)
		}
	}); e != nil {
		return workspaceError(e)
	}
	s.syncStartedHosts()
	out := s.workspaceResult()
	out["source"] = source
	out["ingestion"] = result
	return out
}
func (s *Server) extractWorkspaceAttachment(in map[string]any) map[string]any {
	id := str(in, "id")
	var attachment *store.Attachment
	for _, a := range s.St.WorkspaceSnapshot().Attachments {
		if a.ID == id {
			copy := a
			attachment = &copy
		}
	}
	if attachment == nil {
		return workspaceError(errors.New("attachment not found"))
	}
	data, e := s.St.AttachmentData(id)
	if e != nil {
		return workspaceError(errors.New("attachment file unavailable"))
	}
	// Use a private immutable copy with the original extension for local tools. The
	// tool never receives a model-created path or an executable supplied by a source.
	temp, e := os.MkdirTemp("", "vortex-attachment-")
	if e != nil {
		return workspaceError(e)
	}
	defer os.RemoveAll(temp)
	path := filepath.Join(temp, "source"+filepath.Ext(attachment.Name))
	if e = os.WriteFile(path, data, 0600); e != nil {
		return workspaceError(e)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	state := s.readIngestion()
	result, e := ingest.Extract(ctx, path, attachment.MIMEType, ingest.Detect(state.WhisperModel))
	if e != nil {
		return workspaceError(e)
	}
	e = s.St.UpdateWorkspace(func(w *store.Workspace) error {
		for i := range w.Attachments {
			if w.Attachments[i].ID == id {
				w.Attachments[i].Text = result.Text
				for j := range w.Bases {
					for k := range w.Bases[j].Sources {
						if w.Bases[j].Sources[k].AttachmentID == id {
							w.Bases[j].Sources[k].Text = result.Text
							w.Bases[j].Sources[k].UpdatedAt = time.Now().UTC()
						}
					}
				}
				return nil
			}
		}
		return errors.New("attachment no longer available")
	})
	if e != nil {
		return workspaceError(e)
	}
	if e = s.updateIngestion(func(state *ingestionState) { state.Attachments[id] = result }); e != nil {
		return workspaceError(e)
	}
	s.syncStartedHosts()
	out := s.workspaceResult()
	out["ingestion"] = result
	return out
}

// Only explicitly enabled document subscriptions refresh, only while their Base
// is selected, at most once per five minutes. A failed refresh preserves the last
// snapshot and reports unavailability rather than inventing a successful update.
func (s *Server) refreshDocumentSources(selected map[string]bool) {
	count := 0
	for _, record := range s.readIngestion().Documents {
		if !selected[record.BaseID] || !record.RefreshOnUse || time.Since(record.Result.CheckedAt) < 5*time.Minute {
			continue
		}
		_ = s.fetchDocumentSource(map[string]any{"action": "source.refresh", "baseID": record.BaseID, "sourceID": record.SourceID})
		count++
		if count == 3 {
			break
		}
	}
}
