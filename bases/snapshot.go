package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

// Snapshot is a local owner command input, never an HTTP request. AttachmentPath
// is intentionally absent from Source and therefore cannot enter its manifest.
type Snapshot struct {
	Name    string           `json:"name"`
	Sources []SnapshotSource `json:"sources"`
}

type SnapshotSource struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Kind           string `json:"kind"`
	MIMEType       string `json:"mimeType"`
	Text           string `json:"text,omitempty"`
	URL            string `json:"url,omitempty"`
	AttachmentPath string `json:"attachmentPath,omitempty"`
	Bytes          int64  `json:"bytes"` // Advisory; the host measures actual bytes.
	UpdatedAt      string `json:"updatedAt"`
}

func snapshotSourceID(id string) string {
	hash := sha256.Sum256([]byte(id))
	return hex.EncodeToString(hash[:16])
}

func sourceObjectID(s Source) (string, bool) {
	if s.ObjectID == "" {
		return s.ID, validID(s.ID)
	}
	b, err := hex.DecodeString(s.ObjectID)
	return s.ObjectID, err == nil && len(b) == sha256.Size
}

func (h *Host) syncFile(path string) (Catalog, error) {
	f, err := os.Open(path)
	if err != nil {
		return Catalog{}, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxCatalogBytes {
		return Catalog{}, errors.New("snapshot must be a regular JSON file up to 32 MiB")
	}
	b, err := io.ReadAll(io.LimitReader(f, maxCatalogBytes+1))
	if err != nil {
		return Catalog{}, err
	}
	if len(b) > maxCatalogBytes || !utf8.Valid(b) {
		return Catalog{}, errors.New("snapshot must be UTF-8 JSON up to 32 MiB")
	}
	var snapshot Snapshot
	if err := json.Unmarshal(b, &snapshot); err != nil {
		return Catalog{}, fmt.Errorf("invalid snapshot: %w", err)
	}
	return h.syncSnapshot(snapshot)
}

func validateSnapshotSource(input SnapshotSource) (Source, error) {
	if strings.TrimSpace(input.ID) == "" || len(input.ID) > 512 {
		return Source{}, errors.New("each source requires an ID up to 512 bytes")
	}
	name := strings.TrimSpace(input.Name)
	if name == "" || len(name) > 1024 || !utf8.ValidString(name) {
		return Source{}, errors.New("each source requires a UTF-8 name up to 1024 bytes")
	}
	if len(input.Text) > maxTextBytes || !utf8.ValidString(input.Text) {
		return Source{}, errors.New("source text must be UTF-8 up to 1 MiB")
	}
	if input.URL != "" {
		u, err := url.Parse(input.URL)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || len(input.URL) > 8192 {
			return Source{}, errors.New("source URL must be HTTPS without credentials, query tokens or fragments")
		}
	}
	mt := input.MIMEType
	if mt == "" && input.AttachmentPath != "" {
		mt = mime.TypeByExtension(strings.ToLower(filepath.Ext(input.AttachmentPath)))
	}
	if mt == "" {
		mt = "text/plain"
	}
	if len(mt) > 255 {
		return Source{}, errors.New("source MIME type is too long")
	}
	parsed, _, err := mime.ParseMediaType(mt)
	if err != nil {
		return Source{}, errors.New("source MIME type is invalid")
	}
	kind := input.Kind
	if kind == "file" || kind == "google-doc" {
		kind = "document"
	}
	if kind == "" {
		kind = sourceKind(parsed)
	}
	switch kind {
	case "text", "document", "image", "audio", "video":
	default:
		return Source{}, errors.New("source kind must be text, document, image, audio or video")
	}
	updated := input.UpdatedAt
	if updated == "" {
		updated = time.Now().UTC().Format(time.RFC3339Nano)
	} else if _, err := time.Parse(time.RFC3339Nano, updated); err != nil {
		return Source{}, errors.New("source updatedAt must be RFC3339")
	}
	if input.AttachmentPath == "" && input.Text == "" && input.URL == "" {
		return Source{}, errors.New("source requires text, a document URL or an attachment")
	}
	return Source{ID: snapshotSourceID(input.ID), Name: name, Kind: kind, MIMEType: mt, Text: input.Text, URL: input.URL, Bytes: int64(len(input.Text)), UpdatedAt: updated}, nil
}

func stageSnapshotAttachment(path, stage string) (object string, size int64, err error) {
	if !filepath.IsAbs(path) {
		return "", 0, errors.New("attachmentPath must be an explicit absolute local file path")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", 0, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxSourceBytes {
		return "", 0, errors.New("attachment must be a regular file up to 128 MiB")
	}
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		return "", 0, errors.New("attachment changed while opening")
	}
	out, err := os.CreateTemp(stage, ".source-*")
	if err != nil {
		return "", 0, err
	}
	tmp := out.Name()
	defer os.Remove(tmp)
	hash := sha256.New()
	size, err = io.Copy(io.MultiWriter(out, hash), io.LimitReader(f, maxSourceBytes+1))
	if err == nil && size > maxSourceBytes {
		err = errors.New("attachment exceeded 128 MiB while copying")
	}
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return "", 0, err
	}
	object = hex.EncodeToString(hash.Sum(nil))
	// Same-content attachments may share one immutable object. The per-source
	// quota still accounts for every source independently.
	target := filepath.Join(stage, object)
	if _, err := os.Stat(target); err == nil {
		return object, size, nil
	}
	if err = os.Rename(tmp, target); err != nil {
		return "", 0, err
	}
	return object, size, nil
}

func (h *Host) syncSnapshot(snapshot Snapshot) (Catalog, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c, err := h.load()
	if err != nil {
		return Catalog{}, err
	}
	name := strings.TrimSpace(snapshot.Name)
	if name == "" || len(name) > 1024 || !utf8.ValidString(name) {
		return Catalog{}, errors.New("snapshot requires a UTF-8 name up to 1024 bytes")
	}
	if len(snapshot.Sources) > 1000 {
		return Catalog{}, errors.New("maximum 1000 sources per Base")
	}
	stage, err := os.MkdirTemp(h.dir, ".snapshot-*")
	if err != nil {
		return Catalog{}, err
	}
	defer os.RemoveAll(stage)
	sources := make([]Source, 0, len(snapshot.Sources))
	seen := map[string]bool{}
	used := int64(0)
	for _, input := range snapshot.Sources {
		s, err := validateSnapshotSource(input)
		if err != nil {
			return Catalog{}, err
		}
		if seen[s.ID] {
			return Catalog{}, errors.New("snapshot source IDs must be unique")
		}
		seen[s.ID] = true
		if input.AttachmentPath != "" {
			object, bytes, err := stageSnapshotAttachment(input.AttachmentPath, stage)
			if err != nil {
				return Catalog{}, err
			}
			s.ObjectID, s.SHA256 = object, object
			s.Bytes += bytes
			if s.Kind == "text" && s.Text == "" && bytes <= maxTextBytes {
				if b, err := os.ReadFile(filepath.Join(stage, object)); err == nil && utf8.Valid(b) {
					s.Text = string(b)
					s.Bytes += int64(len(b))
				}
			}
		}
		used += s.Bytes
		if used > c.QuotaBytes {
			return Catalog{}, errors.New("Base storage quota exceeded")
		}
		sources = append(sources, s)
	}
	c.Name, c.Sources = name, sources
	c.Revision++
	// Validate the serialized index before touching any published objects.
	b, err := json.Marshal(c)
	if err != nil || len(b) > maxCatalogBytes {
		return Catalog{}, errors.New("Base metadata/text index exceeds 32 MiB; split this collection into smaller Bases")
	}
	entries, err := os.ReadDir(stage)
	if err != nil {
		return Catalog{}, err
	}
	created := []string{}
	committed := false
	defer func() {
		if !committed {
			for _, path := range created {
				os.Remove(path)
			}
		}
	}()
	for _, entry := range entries {
		dest := filepath.Join(h.dir, "objects", entry.Name())
		if info, err := os.Lstat(dest); err == nil {
			if !info.Mode().IsRegular() {
				return Catalog{}, errors.New("published object is not a regular file")
			}
			// Immutable objects with matching content IDs already exist. The
			// new source continues to reference the same bytes.
			continue
		} else if !os.IsNotExist(err) {
			return Catalog{}, err
		}
		if err := os.Rename(filepath.Join(stage, entry.Name()), dest); err != nil {
			return Catalog{}, err
		}
		created = append(created, dest)
	}
	if err := h.save(c); err != nil {
		return Catalog{}, err
	}
	committed = true
	// Prune only after the catalog switch; a failed update never removes an
	// object referenced by the previous catalog. Unknown owner files stay put.
	keep := map[string]bool{}
	for _, s := range c.Sources {
		if object, ok := sourceObjectID(s); ok {
			keep[object] = true
		}
	}
	if objects, err := os.ReadDir(filepath.Join(h.dir, "objects")); err == nil {
		for _, object := range objects {
			b, err := hex.DecodeString(object.Name())
			if err == nil && (len(b) == 16 || len(b) == sha256.Size) && !keep[object.Name()] {
				os.Remove(filepath.Join(h.dir, "objects", object.Name()))
			}
		}
	}
	return c, nil
}
