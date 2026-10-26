package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestSnapshotPreservesIdentityGrantsAndUpdatesSources(t *testing.T) {
	h, token, _ := fixture(t)
	before, err := h.load()
	if err != nil {
		t.Fatal(err)
	}
	attachment := filepath.Join(t.TempDir(), "notes.txt")
	if err := os.WriteFile(attachment, []byte("first attachment"), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot := Snapshot{Name: "Published notes", Sources: []SnapshotSource{
		{ID: "native-source-7", Name: "Notes", Kind: "text", AttachmentPath: attachment, Bytes: 9999999, UpdatedAt: "2026-10-26T12:00:00Z"},
		{ID: "desktop_reference", Name: "Google document", Kind: "document", Text: "exported document text", URL: "https://docs.google.com/document/d/example/edit"},
	}}
	published, err := h.syncSnapshot(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if published.ID != before.ID || !reflect.DeepEqual(published.Grants, before.Grants) || published.QuotaBytes != before.QuotaBytes || published.Revision != before.Revision+1 {
		t.Fatal("snapshot changed Base identity, quota or grants", published)
	}
	id := snapshotSourceID("native-source-7")
	if published.Sources[0].ID != id || !validID(id) || published.Sources[0].Bytes != int64(2*len("first attachment")) || published.Sources[0].Text != "first attachment" {
		t.Fatal("source was not mapped, indexed or measured", published.Sources[0])
	}
	oldObject := published.Sources[0].ObjectID
	w := request(h, token, "GET", "/v1/sources/"+id)
	if w.Code != 200 || w.Body.String() != "first attachment" {
		t.Fatalf("published attachment unavailable: %d %s", w.Code, w.Body.String())
	}
	w = request(h, token, "GET", "/v1/manifest")
	if strings.Contains(w.Body.String(), attachment) || strings.Contains(w.Body.String(), "objectID") || strings.Contains(w.Body.String(), "attachmentPath") {
		t.Fatal("private publishing details leaked", w.Body.String())
	}
	if err := os.WriteFile(attachment, []byte("updated attachment"), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot.Sources = snapshot.Sources[:1]
	snapshot.Sources[0].Text = "updated supplied transcript"
	published, err = h.syncSnapshot(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if len(published.Sources) != 1 || published.Sources[0].ID != id || published.Sources[0].Text != "updated supplied transcript" {
		t.Fatal("source update/remove failed", published)
	}
	if _, err := os.Stat(filepath.Join(h.dir, "objects", oldObject)); !os.IsNotExist(err) {
		t.Fatal("removed immutable object was not pruned", err)
	}
	w = request(h, token, "GET", "/v1/sources/"+id)
	if w.Code != 200 || w.Body.String() != "updated attachment" {
		t.Fatal("changed bytes were not published", w.Code, w.Body.String())
	}
	if w = request(h, token, "GET", "/v1/health"); w.Code != 200 {
		t.Fatal("existing grant stopped working", w.Code)
	}
}

func TestSnapshotQuotaFailureLeavesPublishedCatalogAndObjects(t *testing.T) {
	h, token, _ := fixture(t)
	attachment := filepath.Join(t.TempDir(), "data.bin")
	os.WriteFile(attachment, []byte("original"), 0600)
	first, err := h.syncSnapshot(Snapshot{Name: "Original", Sources: []SnapshotSource{{ID: "one", Name: "Original", AttachmentPath: attachment}}})
	if err != nil {
		t.Fatal(err)
	}
	first.QuotaBytes = 16
	if err := h.save(first); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(h.dir, "catalog.json"))
	os.WriteFile(attachment, []byte("too large for the configured quota"), 0600)
	if _, err := h.syncSnapshot(Snapshot{Name: "Changed", Sources: []SnapshotSource{{ID: "one", Name: "Updated", AttachmentPath: attachment, Bytes: 0}}}); err == nil {
		t.Fatal("snapshot bypassed quota with advisory byte value")
	}
	after, _ := os.ReadFile(filepath.Join(h.dir, "catalog.json"))
	if string(before) != string(after) {
		t.Fatal("failed snapshot replaced catalog")
	}
	objects, _ := os.ReadDir(filepath.Join(h.dir, "objects"))
	if len(objects) != 1 {
		t.Fatal("failed snapshot left new published objects", objects)
	}
	w := request(h, token, "GET", "/v1/sources/"+first.Sources[0].ID)
	if w.Code != 200 || w.Body.String() != "original" {
		t.Fatal("failed snapshot damaged original file", w.Code, w.Body.String())
	}
}

func TestSnapshotRejectsUnsafePathsMetadataAndDuplicates(t *testing.T) {
	h, _, _ := fixture(t)
	path := filepath.Join(t.TempDir(), "attachment")
	os.WriteFile(path, []byte("private"), 0600)
	link := filepath.Join(t.TempDir(), "symlink")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	for _, source := range []SnapshotSource{
		{ID: "1", Name: "Relative", AttachmentPath: "relative.txt"},
		{ID: "1", Name: "Symlink", AttachmentPath: link},
		{ID: "1", Name: "Directory", AttachmentPath: t.TempDir()},
		{ID: "1", Name: "Credentials", Text: "text", URL: "https://example.com/?token=private"},
		{ID: "1", Name: "Bad type", Text: "text", MIMEType: "bad\r\nheader"},
		{ID: "1", Name: "Bad date", Text: "text", UpdatedAt: "yesterday"},
	} {
		if _, err := h.syncSnapshot(Snapshot{Name: "Invalid", Sources: []SnapshotSource{source}}); err == nil {
			t.Fatalf("accepted invalid source: %#v", source)
		}
	}
	s := SnapshotSource{ID: "duplicate", Name: "Same ID", Text: "text"}
	if _, err := h.syncSnapshot(Snapshot{Name: "Duplicate", Sources: []SnapshotSource{s, s}}); err == nil {
		t.Fatal("accepted duplicate source IDs")
	}
	f, err := os.Create(filepath.Join(t.TempDir(), "large.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(maxSourceBytes + 1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := h.syncSnapshot(Snapshot{Name: "Too large", Sources: []SnapshotSource{{ID: "large", Name: "Large", AttachmentPath: f.Name()}}}); err == nil {
		t.Fatal("accepted oversized attachment")
	}
}

func TestSnapshotSharedAttachmentDeletionAndEmptySnapshot(t *testing.T) {
	h, token, _ := fixture(t)
	path := filepath.Join(t.TempDir(), "shared.bin")
	os.WriteFile(path, []byte("shared content"), 0600)
	c, err := h.syncSnapshot(Snapshot{Name: "Shared", Sources: []SnapshotSource{
		{ID: "a", Name: "A", AttachmentPath: path},
		{ID: "b", Name: "B", AttachmentPath: path},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.remove(c.Sources[0].ID); err != nil {
		t.Fatal(err)
	}
	if w := request(h, token, "GET", "/v1/sources/"+c.Sources[1].ID); w.Code != 200 {
		t.Fatal("deleting one source removed shared bytes", w.Code)
	}
	c, err = h.syncSnapshot(Snapshot{Name: "Empty", Sources: []SnapshotSource{}})
	if err != nil || len(c.Sources) != 0 {
		t.Fatal("could not publish empty snapshot", err)
	}
	objects, _ := os.ReadDir(filepath.Join(h.dir, "objects"))
	if len(objects) != 0 {
		t.Fatal("empty snapshot did not prune removed attachments")
	}
}

func captureOutput(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	original := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	defer func() { os.Stdout = original }()
	err = fn()
	w.Close()
	b, readErr := io.ReadAll(r)
	r.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	return string(b), err
}

func TestSyncAndGrantMachineOutput(t *testing.T) {
	h, _, _ := fixture(t)
	snapshot := filepath.Join(t.TempDir(), "snapshot.json")
	os.WriteFile(snapshot, []byte(`{"name":"Managed","sources":[{"id":"native-id","name":"Manual text","text":"reference context"}]}`), 0600)
	output, err := captureOutput(t, func() error { return run([]string{"sync", "-dir", h.dir, "-snapshot", snapshot}) })
	var status struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		Sources  int    `json:"sources"`
		Revision int    `json:"revision"`
	}
	if err != nil || json.Unmarshal([]byte(output), &status) != nil || status.Name != "Managed" || status.Sources != 1 || !validID(status.ID) {
		t.Fatal("sync did not return machine status", output, err)
	}
	tokenPath := filepath.Join(t.TempDir(), "token")
	output, err = captureOutput(t, func() error {
		return run([]string{"grant", "-dir", h.dir, "-out", tokenPath, "-json", "-scopes", "read", "-days", "7"})
	})
	var grant struct {
		ID        string   `json:"id"`
		TokenFile string   `json:"tokenFile"`
		Scopes    []string `json:"scopes"`
		ExpiresAt string   `json:"expiresAt"`
	}
	token, _ := os.ReadFile(tokenPath)
	if err != nil || json.Unmarshal([]byte(output), &grant) != nil || !validID(grant.ID) || grant.TokenFile != tokenPath || !reflect.DeepEqual(grant.Scopes, []string{"read"}) || grant.ExpiresAt == "" || strings.Contains(output, strings.TrimSpace(string(token))) {
		t.Fatal("unsafe or invalid JSON grant output", output, err)
	}
}

func TestServeReadinessUsesActualPortAndCleansUp(t *testing.T) {
	h, token, _ := fixture(t)
	ready := filepath.Join(t.TempDir(), "ready.json")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- serve(ctx, h, serveOptions{Listen: "127.0.0.1:0", ReadyFile: ready}) }()
	var state readyState
	deadline := time.Now().Add(3 * time.Second)
	for {
		b, err := os.ReadFile(ready)
		if err == nil && json.Unmarshal(b, &state) == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("readiness file never appeared")
		}
		time.Sleep(10 * time.Millisecond)
	}
	c, _ := h.load()
	if state.BaseID != c.ID || state.PID != os.Getpid() || !strings.HasPrefix(state.Endpoint, "http://127.0.0.1:") || strings.HasSuffix(state.Endpoint, ":0") {
		t.Fatal("invalid readiness metadata", state)
	}
	info, _ := os.Stat(ready)
	if info.Mode().Perm() != 0600 {
		t.Fatal("readiness file is not private")
	}
	client := &http.Client{Timeout: time.Second}
	req, _ := http.NewRequest("GET", state.Endpoint+"/v1/health", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := client.Do(req)
	if err != nil {
		t.Fatal("reported endpoint is not usable", err)
	}
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatal("reported endpoint rejected existing grant", response.StatusCode)
	}
	cancel()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal("graceful stop failed", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("host did not stop gracefully")
	}
	if _, err := os.Stat(ready); !os.IsNotExist(err) {
		t.Fatal("readiness file remains after shutdown", err)
	}
	if _, err := client.Get(state.Endpoint + "/v1/health"); err == nil {
		t.Fatal("listener remains open after shutdown")
	}
}

func TestSnapshotAcceptsNativeAndDesktopDocumentAliases(t *testing.T) {
	for _, kind := range []string{"file", "google-doc"} {
		h, _, _ := fixture(t)
		catalog, err := h.syncSnapshot(Snapshot{Name: "Client compatibility", Sources: []SnapshotSource{{ID: "client-id", Name: "Document", Kind: kind, Text: "Imported client text"}}})
		if err != nil || len(catalog.Sources) != 1 || catalog.Sources[0].Kind != "document" {
			t.Fatalf("client source alias %s was not normalized: %v", kind, err)
		}
	}
}
