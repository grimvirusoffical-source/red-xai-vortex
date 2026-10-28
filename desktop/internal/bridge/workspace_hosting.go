package bridge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

type managedHost struct {
	cmd            *exec.Cmd
	running        bool
	endpoint       string
	publicEndpoint string
	baseID         string
	lastError      string
	done           chan struct{}
	lastSnapshot   string
}
type hostingGrant struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Scopes    []string `json:"scopes"`
	ExpiresAt string   `json:"expiresAt"`
}
type hostingStatus struct {
	Running        bool           `json:"running"`
	Available      bool           `json:"available"`
	Endpoint       string         `json:"endpoint,omitempty"`
	PublicEndpoint string         `json:"publicEndpoint,omitempty"`
	BaseID         string         `json:"baseID,omitempty"`
	SourceCount    int            `json:"sourceCount"`
	Revision       int            `json:"revision"`
	Grants         []hostingGrant `json:"grants"`
	Error          string         `json:"error,omitempty"`
}

func baseHelperPath() (string, error) {
	if p := os.Getenv("VORTEX_BASE_HELPER"); p != "" {
		info, err := os.Stat(p)
		if err != nil || !info.Mode().IsRegular() {
			return "", errors.New("configured Base helper is unavailable")
		}
		return p, nil
	}
	if len(BundledBaseHelper) > 0 {
		return cachedBundledBaseHelper()
	}
	name := "vortex-base"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	exe, _ := os.Executable()
	for _, p := range []string{filepath.Join(filepath.Dir(exe), name), filepath.Join(filepath.Dir(exe), "..", "Resources", name)} {
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
			return p, nil
		}
	}
	if p, err := exec.LookPath(name); err == nil {
		return p, nil
	}
	return "", errors.New("Base hosting helper unavailable; install the complete Vortex release or set VORTEX_BASE_HELPER")
}
func (s *Server) hostDir(id string) string { return filepath.Join(s.St.Dir, "hosting", id) }
func helperJSON(helper string, args []string, out any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, helper, args...)
	var output bytes.Buffer
	cmd.Stdout = &cappedHelperOutput{buffer: &output, limit: 2 << 20}
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return errors.New("Base helper operation failed; check the source files, quota and hosting configuration")
	}
	if output.Len() > 2<<20 {
		return errors.New("Base helper response too large")
	}
	if out != nil {
		if err := json.Unmarshal(output.Bytes(), out); err != nil {
			return errors.New("Base helper returned invalid JSON")
		}
	}
	return nil
}
func (s *Server) findLocalBase(id string) (store.Base, error) {
	for _, b := range s.St.WorkspaceSnapshot().Bases {
		if b.ID == id {
			if b.Endpoint != "" {
				return b, errors.New("only locally owned Bases can be hosted")
			}
			return b, nil
		}
	}
	return store.Base{}, errors.New("Base not found")
}
func (s *Server) syncManagedBaseLocked(helper string, b store.Base) error {
	filtered := store.Workspace{Bases: []store.Base{b}}
	s.filterUnavailableDocuments(&filtered)
	if len(filtered.Bases) > 0 {
		b = filtered.Bases[0]
	}
	dir := s.hostDir(b.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(dir, "catalog.json")); os.IsNotExist(err) {
		if err = helperJSON(helper, []string{"init", "-dir", dir, "-name", b.Name}, nil); err != nil {
			return err
		}
	}
	type publishedSource struct {
		store.Source
		AttachmentPath string `json:"attachmentPath,omitempty"`
	}
	snapshot := struct {
		Name    string            `json:"name"`
		Sources []publishedSource `json:"sources"`
	}{Name: b.Name, Sources: []publishedSource{}}
	for _, source := range b.Sources {
		item := publishedSource{Source: source}
		if source.AttachmentID != "" {
			if !store.ValidAttachmentID(source.AttachmentID) {
				return errors.New("invalid Base attachment ID")
			}
			item.AttachmentPath = filepath.Join(s.St.Dir, "attachments", source.AttachmentID)
		}
		snapshot.Sources = append(snapshot.Sources, item)
	}
	raw, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	hash := sha256.Sum256(raw)
	digest := hex.EncodeToString(hash[:])
	if host := s.hosts[b.ID]; host != nil && host.lastSnapshot == digest {
		return nil
	}
	path := filepath.Join(dir, "publish.json")
	if err = os.WriteFile(path, raw, 0600); err != nil {
		return err
	}
	if err = helperJSON(helper, []string{"sync", "-dir", dir, "-snapshot", path}, nil); err != nil {
		return err
	}
	if host := s.hosts[b.ID]; host != nil {
		host.lastSnapshot = digest
	}
	return nil
}
func (s *Server) syncStartedHosts() error {
	s.hostingMu.Lock()
	defer s.hostingMu.Unlock()
	if len(s.hosts) == 0 {
		return nil
	}
	helper, err := baseHelperPath()
	if err != nil {
		return err
	}
	var first error
	for id, host := range s.hosts {
		if !host.running {
			continue
		}
		b, e := s.findLocalBase(id)
		if e != nil {
			continue
		}
		if e = s.syncManagedBaseLocked(helper, b); e != nil {
			host.lastError = e.Error()
			if first == nil {
				first = e
			}
		} else {
			host.lastError = ""
		}
	}
	return first
}
func (s *Server) hostStatusLocked(id string) hostingStatus {
	helper, err := baseHelperPath()
	st := hostingStatus{Available: err == nil, Grants: []hostingGrant{}}
	if err != nil {
		st.Error = err.Error()
	}
	if host := s.hosts[id]; host != nil {
		st.Running = host.running
		st.Endpoint = host.endpoint
		st.PublicEndpoint = host.publicEndpoint
		st.BaseID = host.baseID
		st.Error = host.lastError
	}
	var catalog struct {
		ID       string         `json:"id"`
		Revision int            `json:"revision"`
		Sources  int            `json:"sources"`
		Grants   []hostingGrant `json:"grants"`
	}
	if helper != "" {
		if e := helperJSON(helper, []string{"status", "-dir", s.hostDir(id)}, &catalog); e == nil {
			st.BaseID = catalog.ID
			st.Revision = catalog.Revision
			st.SourceCount = catalog.Sources
			st.Grants = catalog.Grants
		}
	}
	return st
}
func validateHostConfig(c store.HostingConfig) (store.HostingConfig, error) {
	if c.Listen == "" {
		c.Listen = "127.0.0.1:0"
	}
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return c, errors.New("listen address must include an IP and port")
	}
	ip := net.ParseIP(host)
	if (ip == nil || !ip.IsLoopback()) && (c.TLSCert == "" || c.TLSKey == "") {
		return c, errors.New("non-loopback Base hosting requires explicit TLS certificate and private-key paths")
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return c, errors.New("both TLS certificate and key are required")
	}
	if c.PublicEndpoint != "" {
		u, e := url.Parse(c.PublicEndpoint)
		if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
			return c, errors.New("invite endpoint must be an HTTPS origin configured through your TLS proxy or tunnel")
		}
		c.PublicEndpoint = strings.TrimRight(c.PublicEndpoint, "/")
	}
	return c, nil
}
func (s *Server) saveHostConfig(id string, c *store.HostingConfig) error {
	return s.St.UpdateWorkspace(func(w *store.Workspace) error {
		for i := range w.Bases {
			if w.Bases[i].ID == id {
				w.Bases[i].Hosting = c
				return nil
			}
		}
		return errors.New("Base no longer exists")
	})
}
func (s *Server) startManagedHost(id string, c store.HostingConfig) (hostingStatus, error) {
	c, err := validateHostConfig(c)
	if err != nil {
		return hostingStatus{}, err
	}
	b, err := s.findLocalBase(id)
	if err != nil {
		return hostingStatus{}, err
	}
	helper, err := baseHelperPath()
	if err != nil {
		return hostingStatus{}, err
	}
	s.hostingMu.Lock()
	defer s.hostingMu.Unlock()
	if s.hosts == nil {
		s.hosts = map[string]*managedHost{}
	}
	if old := s.hosts[id]; old != nil && old.running {
		return s.hostStatusLocked(id), nil
	}
	if err = s.syncManagedBaseLocked(helper, b); err != nil {
		return hostingStatus{}, err
	}
	dir := s.hostDir(id)
	ready := filepath.Join(dir, "ready.json")
	_ = os.Remove(ready)
	args := []string{"serve", "-dir", dir, "-listen", c.Listen, "-ready-file", ready, "-parent-pid", fmt.Sprint(os.Getpid())}
	if c.TLSCert != "" {
		args = append(args, "-tls-cert", c.TLSCert, "-tls-key", c.TLSKey)
	}
	cmd := exec.Command(helper, args...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if s.profileClosed.Load() {
		return hostingStatus{}, errors.New("account session ended")
	}
	if err = cmd.Start(); err != nil {
		return hostingStatus{}, errors.New("Base helper could not start")
	}
	host := &managedHost{cmd: cmd, running: true, publicEndpoint: c.PublicEndpoint, done: make(chan struct{})}
	s.hosts[id] = host
	go func() {
		err := cmd.Wait()
		s.hostingMu.Lock()
		host.running = false
		if err != nil && host.lastError == "" {
			host.lastError = "Base host stopped unexpectedly"
		}
		close(host.done)
		s.hostingMu.Unlock()
	}()
	deadline := time.Now().Add(5 * time.Second)
	var report struct {
		Endpoint string `json:"endpoint"`
		BaseID   string `json:"baseID"`
	}
	for time.Now().Before(deadline) {
		raw, e := os.ReadFile(ready)
		if e == nil && json.Unmarshal(raw, &report) == nil && report.Endpoint != "" && report.BaseID != "" {
			host.endpoint = report.Endpoint
			host.baseID = report.BaseID
			c.Enabled = true
			if e = s.saveHostConfig(id, &c); e != nil {
				_ = cmd.Process.Kill()
				return hostingStatus{}, e
			}
			return s.hostStatusLocked(id), nil
		}
		time.Sleep(40 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	host.lastError = "Base host did not become ready; check its listener and TLS files"
	return hostingStatus{}, errors.New(host.lastError)
}
func (s *Server) stopManagedHost(id string, persist bool) error {
	s.hostingMu.Lock()
	host := s.hosts[id]
	if host != nil && host.running {
		if runtime.GOOS == "windows" {
			_ = host.cmd.Process.Kill()
		} else {
			_ = host.cmd.Process.Signal(os.Interrupt)
		}
		host.lastError = ""
	}
	s.hostingMu.Unlock()
	if host != nil {
		select {
		case <-host.done:
		case <-time.After(2 * time.Second):
			_ = host.cmd.Process.Kill()
		}
	}
	if persist {
		b, err := s.findLocalBase(id)
		if err == nil && b.Hosting != nil {
			c := *b.Hosting
			c.Enabled = false
			return s.saveHostConfig(id, &c)
		}
	}
	return nil
}
func (s *Server) restoreManagedHosts() {
	if s.profileClosed.Load() {
		return
	}
	for _, b := range s.St.WorkspaceSnapshot().Bases {
		if b.Hosting != nil && b.Hosting.Enabled && b.Endpoint == "" {
			_, _ = s.startManagedHost(b.ID, *b.Hosting)
		}
	}
}
func (s *Server) workspaceHostAction(in map[string]any) map[string]any {
	id := str(in, "id")
	if !store.ValidAttachmentID(id) {
		return workspaceError(errors.New("valid Base ID required"))
	}
	if _, err := s.findLocalBase(id); err != nil {
		return workspaceError(err)
	}
	action := str(in, "action")
	if action == "host.start" {
		config := store.HostingConfig{Listen: str(in, "listen"), PublicEndpoint: str(in, "publicEndpoint"), TLSCert: str(in, "tlsCert"), TLSKey: str(in, "tlsKey")}
		if _, err := s.startManagedHost(id, config); err != nil {
			return workspaceError(err)
		}
	}
	if action == "host.stop" {
		if err := s.stopManagedHost(id, true); err != nil {
			return workspaceError(err)
		}
	}
	s.hostingMu.Lock()
	defer s.hostingMu.Unlock()
	if action == "host.status" || action == "host.stop" {
		out := s.workspaceResult()
		out["hosting"] = s.hostStatusLocked(id)
		return out
	}
	helper, err := baseHelperPath()
	if err != nil {
		return workspaceError(err)
	}
	switch action {
	case "host.sync":
		if host := s.hosts[id]; host != nil {
			host.lastSnapshot = ""
		}
		b, _ := s.findLocalBase(id)
		if err = s.syncManagedBaseLocked(helper, b); err != nil {
			return workspaceError(err)
		}
	case "host.grant":
		if status := s.hostStatusLocked(id); !status.Running {
			return workspaceError(errors.New("start hosting this Base before creating an invite"))
		}
		name := strings.TrimSpace(str(in, "name"))
		if name == "" {
			name = "Shared access"
		}
		days := 30
		if v, ok := in["days"].(float64); ok {
			days = int(v)
		}
		if days < 1 || days > 365 {
			return workspaceError(errors.New("invite expiry must be 1–365 days"))
		}
		scopes := []string{}
		if values, ok := in["scopes"].([]any); ok {
			for _, v := range values {
				scope, _ := v.(string)
				if scope != "read" && scope != "search" {
					return workspaceError(errors.New("invite scopes must be read or search"))
				}
				scopes = append(scopes, scope)
			}
		}
		if len(scopes) == 0 {
			scopes = []string{"read", "search"}
		}
		b, _ := s.findLocalBase(id)
		if err = s.syncManagedBaseLocked(helper, b); err != nil {
			return workspaceError(err)
		}
		path := filepath.Join(s.hostDir(id), workspaceID("invite")+".token")
		defer os.Remove(path)
		var grant struct {
			ID        string `json:"id"`
			ExpiresAt string `json:"expiresAt"`
		}
		if err = helperJSON(helper, []string{"grant", "-dir", s.hostDir(id), "-name", name, "-out", path, "-days", fmt.Sprint(days), "-scopes", strings.Join(scopes, ","), "-json"}, &grant); err != nil {
			return workspaceError(err)
		}
		raw, e := os.ReadFile(path)
		if e != nil {
			return workspaceError(errors.New("invite token could not be read"))
		}
		status := s.hostStatusLocked(id)
		endpoint := status.PublicEndpoint
		if endpoint == "" {
			endpoint = status.Endpoint
		}
		out := s.workspaceResult()
		out["hosting"] = status
		out["invite"] = map[string]any{"endpoint": endpoint, "remoteID": status.BaseID, "token": strings.TrimSpace(string(raw)), "grantID": grant.ID, "expiresAt": grant.ExpiresAt}
		return out
	case "host.revoke":
		if err = helperJSON(helper, []string{"revoke", "-dir", s.hostDir(id), "-id", str(in, "grantID")}, nil); err != nil {
			return workspaceError(err)
		}
	case "host.start", "host.stop", "host.status":
	default:
		return workspaceError(errors.New("unknown hosting action"))
	}
	out := s.workspaceResult()
	out["hosting"] = s.hostStatusLocked(id)
	return out
}

func (s *Server) deleteManagedPublication(id string) error {
	if !store.ValidAttachmentID(id) {
		return errors.New("invalid Base ID")
	}
	if err := s.stopManagedHost(id, false); err != nil {
		return err
	}
	s.hostingMu.Lock()
	delete(s.hosts, id)
	s.hostingMu.Unlock()
	return os.RemoveAll(s.hostDir(id))
}

type cappedHelperOutput struct {
	buffer *bytes.Buffer
	limit  int
}

func (w *cappedHelperOutput) Write(p []byte) (int, error) {
	if w.buffer.Len()+len(p) > w.limit {
		return 0, errors.New("helper output exceeded its limit")
	}
	return w.buffer.Write(p)
}
