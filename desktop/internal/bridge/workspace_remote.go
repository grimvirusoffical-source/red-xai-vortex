package bridge

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func validateBaseEndpoint(endpoint string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("Base endpoint must be a host URL without credentials, query or fragment")
	}
	if u.Scheme != "https" {
		ip := net.ParseIP(u.Hostname())
		loopback := strings.EqualFold(u.Hostname(), "localhost") || (ip != nil && ip.IsLoopback())
		if u.Scheme != "http" || !loopback {
			return "", errors.New("remote Bases require HTTPS; HTTP is allowed only on loopback")
		}
	}
	if u.Path != "" && u.Path != "/" {
		return "", errors.New("Base endpoint must be the host origin, without an API path")
	}
	return strings.TrimRight(u.String(), "/"), nil
}

// Never follow a redirect with a Base credential. Errors are deliberately generic:
// host URLs and tokens must not leak to context, logs or general connection status.
func (s *Server) remoteBaseJSON(b store.Base, path string, out any) error {
	endpoint, err := validateBaseEndpoint(b.Endpoint)
	if err != nil {
		return err
	}
	token := ""
	if s.baseCredential != nil {
		token = s.baseCredential(b.ID)
	} else {
		token = s.secretGet("base-token-" + b.ID)
	}
	if token == "" {
		return errors.New("Base access token missing; reconnect this Base")
	}
	req, err := http.NewRequest(http.MethodGet, endpoint+path, nil)
	if err != nil {
		return errors.New("invalid Base request")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	if b.RemoteID != "" {
		req.Header.Set("X-Vortex-Base-ID", b.RemoteID)
	}
	client := &http.Client{Timeout: 4 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := client.Do(req)
	if err != nil {
		return errors.New("Base host unavailable; check its connection and TLS certificate")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		if res.StatusCode == 401 || res.StatusCode == 403 {
			return errors.New("Base access denied or token revoked")
		}
		return fmt.Errorf("Base host returned HTTP %d", res.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(res.Body, (4<<20)+1))
	if err != nil {
		return errors.New("Base response could not be read")
	}
	if len(raw) > 4<<20 {
		return errors.New("Base response exceeds 4 MiB")
	}
	if err = json.Unmarshal(raw, out); err != nil {
		return errors.New("Base host returned invalid JSON")
	}
	return nil
}

type baseManifest struct {
	ID       string         `json:"id"`
	Name     string         `json:"name"`
	Sources  []store.Source `json:"sources"`
	Revision any            `json:"revision"`
}

func baseRevision(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func (s *Server) checkRemoteBase(b *store.Base) error {
	var health map[string]any
	if err := s.remoteBaseJSON(*b, "/v1/health", &health); err != nil {
		return err
	}
	var manifest baseManifest
	if err := s.remoteBaseJSON(*b, "/v1/manifest", &manifest); err != nil {
		return err
	}
	if manifest.ID == "" {
		return errors.New("Base manifest has no ID")
	}
	if b.RemoteID != "" && manifest.ID != b.RemoteID {
		return errors.New("Base identity mismatch; reconnect with the intended Base ID")
	}
	if len(manifest.Sources) > 10000 {
		return errors.New("Base manifest has too many sources")
	}
	for _, src := range manifest.Sources {
		if err := validateSource(src); err != nil {
			return fmt.Errorf("invalid Base manifest: %w", err)
		}
	}
	b.RemoteID = manifest.ID
	b.Sources = manifest.Sources
	b.Revision = baseRevision(manifest.Revision)
	b.Status = "online"
	b.LastError = ""
	now := time.Now().UTC()
	b.LastChecked = &now
	b.UpdatedAt = now
	return nil
}
func (s *Server) workspaceBaseAction(action string, in map[string]any) map[string]any {
	id := str(in, "id")
	if !store.ValidAttachmentID(id) {
		return workspaceError(errors.New("valid Base ID required"))
	}
	var base store.Base
	found := false
	for _, b := range s.St.WorkspaceSnapshot().Bases {
		if b.ID == id {
			base = b
			found = true
			break
		}
	}
	if !found {
		return workspaceError(errors.New("Base not found"))
	}
	if action == "base.disconnect" || action == "base.revoke" {
		if err := s.secretSet("base-token-"+id, ""); err != nil {
			return workspaceError(errors.New("could not remove Base credential"))
		}
		base.Status = "disconnected"
		if action == "base.revoke" {
			base.Status = "revoked"
		}
		base.Sources = []store.Source{}
		base.LastError = ""
		if err := s.persistBase(base); err != nil {
			return workspaceError(err)
		}
		out := s.workspaceResult()
		if action == "base.revoke" {
			out["message"] = "Local access removed. To invalidate copies of this token, revoke it on the Base host as well."
		}
		return out
	}
	if action == "base.connect" {
		endpoint, err := validateBaseEndpoint(str(in, "endpoint"))
		if err != nil {
			return workspaceError(err)
		}
		token := strings.TrimSpace(str(in, "token"))
		if token == "" || len(token) > 8192 || strings.ContainsAny(token, "\r\n") {
			return workspaceError(errors.New("a valid Base access token is required"))
		}
		base.Endpoint = endpoint
		base.RemoteID = str(in, "remoteID")
		if err = s.secretSet("base-token-"+id, token); err != nil {
			return workspaceError(errors.New("could not store Base credential"))
		}
	}
	if base.Endpoint == "" {
		return workspaceError(errors.New("connect this Base to a host first"))
	}
	if !base.Permissions.Read {
		return workspaceError(errors.New("read permission is disabled for this Base"))
	}
	err := s.checkRemoteBase(&base)
	if err != nil {
		now := time.Now().UTC()
		base.LastChecked = &now
		base.LastError = err.Error()
		base.Status = "offline"
		base.Sources = []store.Source{}
	}
	if saveErr := s.persistBase(base); saveErr != nil {
		return workspaceError(saveErr)
	}
	out := s.workspaceResult()
	if err != nil {
		out["ok"] = false
		out["error"] = err.Error()
		out["message"] = err.Error()
	}
	return out
}
func (s *Server) persistBase(b store.Base) error {
	return s.St.UpdateWorkspace(func(w *store.Workspace) error {
		for i := range w.Bases {
			if w.Bases[i].ID == b.ID {
				w.Bases[i] = b
				return nil
			}
		}
		return errors.New("Base no longer exists")
	})
}
func (s *Server) workspaceRemoteSearch(b store.Base, query string) map[string]any {
	if !b.Permissions.Read || !b.Permissions.Search {
		return workspaceError(errors.New("Base read/search permission is disabled"))
	}
	if b.Status != "online" {
		return workspaceError(errors.New("Base is not connected; run its health check or reconnect"))
	}
	if len(query) > 4096 {
		return workspaceError(errors.New("search query too long"))
	}
	var result struct {
		Sources []store.Source `json:"sources"`
	}
	if err := s.remoteBaseJSON(b, "/v1/search?q="+url.QueryEscape(query), &result); err != nil {
		return workspaceError(err)
	}
	if len(result.Sources) > 20 {
		result.Sources = result.Sources[:20]
	}
	for _, src := range result.Sources {
		if err := validateSource(src); err != nil {
			return workspaceError(errors.New("invalid Base search results"))
		}
	}
	return map[string]any{"ok": true, "sources": result.Sources}
}

// Refresh selected remote context on every completion. A previous successful
// manifest is never evidence that a revoked credential still grants access.
func (s *Server) refreshContextBases(w store.Workspace, selected map[string]bool) store.Workspace {
	type checked struct{ base store.Base }
	results := make(chan checked, 4)
	count := 0
	for _, b := range w.Bases {
		if !selected[b.ID] || b.Endpoint == "" || !b.Permissions.Read || !b.Permissions.Search || b.Status == "disconnected" || b.Status == "revoked" {
			continue
		}
		if count >= 4 {
			selected[b.ID] = false
			continue
		}
		count++
		go func(b store.Base) {
			var manifest baseManifest
			err := s.remoteBaseJSON(b, "/v1/manifest", &manifest)
			if err == nil && (manifest.ID == "" || manifest.ID != b.RemoteID) {
				err = errors.New("Base identity mismatch")
			}
			if err == nil {
				for _, src := range manifest.Sources {
					if e := validateSource(src); e != nil {
						err = errors.New("invalid Base manifest")
						break
					}
				}
			}
			now := time.Now().UTC()
			b.LastChecked = &now
			if err != nil {
				b.Status = "offline"
				b.LastError = err.Error()
				b.Sources = []store.Source{}
			} else {
				b.Status = "online"
				b.LastError = ""
				b.Sources = manifest.Sources
				b.Revision = baseRevision(manifest.Revision)
			}
			results <- checked{base: b}
		}(b)
	}
	for i := 0; i < count; i++ {
		result := <-results
		for j := range w.Bases {
			if w.Bases[j].ID == result.base.ID {
				w.Bases[j] = result.base
				break
			}
		}
		_ = s.St.UpdateWorkspace(func(current *store.Workspace) error {
			for j := range current.Bases {
				old := &current.Bases[j]
				if old.ID == result.base.ID && old.Endpoint == result.base.Endpoint && old.RemoteID == result.base.RemoteID && old.Status != "revoked" && old.Status != "disconnected" {
					old.Sources = result.base.Sources
					old.Status = result.base.Status
					old.LastError = result.base.LastError
					old.LastChecked = result.base.LastChecked
					old.Revision = result.base.Revision
					break
				}
			}
			return nil
		})
	}
	// Network results remain authoritative even if updating the local status file
	// fails. Recheck current permissions and revocation to avoid overwriting an
	// intervening disconnect while a request was in flight.
	current := s.St.WorkspaceSnapshot()
	for i := range w.Bases {
		fresh := &w.Bases[i]
		found := false
		for _, now := range current.Bases {
			if now.ID == fresh.ID {
				found = true
				fresh.Permissions = now.Permissions
				if now.Status == "revoked" || now.Status == "disconnected" || now.Endpoint != fresh.Endpoint || now.RemoteID != fresh.RemoteID {
					fresh.Status = "disconnected"
					fresh.Sources = []store.Source{}
				}
				break
			}
		}
		if !found {
			fresh.Status = "disconnected"
			fresh.Sources = []store.Source{}
		}
	}
	return w
}
