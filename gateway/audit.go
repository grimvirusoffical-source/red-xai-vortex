package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const auditRetention = 10
const auditMigrationLimit = 64 << 20

type auditExport struct {
	IDs         map[string]bool
	Key, Device string
	Expires     time.Time
}

// IDs identify records, rather than row positions, so new events survive deletion.
type auditStore struct {
	mu      sync.Mutex
	Dir     string
	loaded  bool
	events  []map[string]any
	exports map[string]auditExport
}

var ownerAudit = &auditStore{Dir: dir}

func auditID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
func (s *auditStore) persistLocked(events []map[string]any) error {
	f, err := os.CreateTemp(s.Dir, ".audit-*.tmp")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	enc := json.NewEncoder(f)
	for _, e := range events {
		if err = enc.Encode(e); err != nil {
			f.Close()
			return err
		}
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(name, filepath.Join(s.Dir, "audit.jsonl")); err != nil {
		return err
	}
	if d, e := os.Open(s.Dir); e == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
func (s *auditStore) loadLocked() error {
	if s.loaded {
		return nil
	}
	f, err := os.Open(filepath.Join(s.Dir, "audit.jsonl"))
	if errors.Is(err, os.ErrNotExist) {
		s.loaded = true
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() || st.Size() > auditMigrationLimit {
		return fmt.Errorf("audit history needs an offline backup before migration (limit %d bytes)", auditMigrationLimit)
	}
	var events []map[string]any
	seen := map[string]bool{}
	changed := false
	count := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 4096), 64<<10)
	for sc.Scan() {
		count++
		var e map[string]any
		if json.Unmarshal(sc.Bytes(), &e) != nil || e == nil {
			return fmt.Errorf("invalid audit record %d; original file preserved", count)
		}
		id, _ := e["id"].(string)
		_, decodeErr := hex.DecodeString(id)
		if len(id) != 32 || decodeErr != nil || seen[id] {
			id, err = auditID()
			if err != nil {
				return err
			}
			e["id"] = id
			changed = true
		}
		seen[id] = true
		events = append(events, e)
		if len(events) > auditRetention {
			delete(seen, events[0]["id"].(string))
			events = events[1:]
			changed = true
		}
	}
	if err = sc.Err(); err != nil {
		return err
	}
	if changed {
		// Save exact private legacy bytes before IDs are assigned or records trimmed.
		backup, e := os.CreateTemp(s.Dir, "audit-before-retention-*.jsonl")
		if e != nil {
			return e
		}
		good := false
		defer func() {
			backup.Close()
			if !good {
				os.Remove(backup.Name())
			}
		}()
		if _, e = f.Seek(0, io.SeekStart); e != nil {
			return e
		}
		if _, e = io.Copy(backup, io.LimitReader(f, auditMigrationLimit+1)); e != nil {
			return e
		}
		if e = backup.Sync(); e != nil {
			return e
		}
		if e = backup.Close(); e != nil {
			return e
		}
		good = true
		if e = s.persistLocked(events); e != nil {
			return e
		}
	}
	s.events = events
	s.loaded = true
	return nil
}
func (s *auditStore) append(e map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return err
	}
	id, err := auditID()
	if err != nil {
		return err
	}
	e["id"] = id
	next := append(append([]map[string]any{}, s.events...), e)
	if len(next) > auditRetention {
		next = next[len(next)-auditRetention:]
	}
	if err = s.persistLocked(next); err != nil {
		return err
	}
	s.events = next
	return nil
}
func (s *auditStore) listLocked(ids map[string]bool) []map[string]any {
	out := []map[string]any{}
	for i := len(s.events) - 1; i >= 0; i-- {
		e := s.events[i]
		id, _ := e["id"].(string)
		if ids == nil || ids[id] {
			copy := map[string]any{}
			for k, v := range e {
				copy[k] = v
			}
			out = append(out, copy)
		}
	}
	return out
}
func (s *auditStore) list() ([]map[string]any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return nil, err
	}
	return s.listLocked(nil), nil
}
func (s *auditStore) clearLocked(ids map[string]bool) (int, error) {
	next := []map[string]any{}
	removed := 0
	for _, e := range s.events {
		id, _ := e["id"].(string)
		if ids[id] {
			removed++
		} else {
			next = append(next, e)
		}
	}
	if removed > 0 {
		if err := s.persistLocked(next); err != nil {
			return 0, err
		}
		s.events = next
	}
	return removed, nil
}
func (s *auditStore) clear(ids map[string]bool) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return 0, err
	}
	return s.clearLocked(ids)
}
func (s *auditStore) prepareExport(ids map[string]bool, key, device string) (map[string]any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.loadLocked(); err != nil {
		return nil, err
	}
	if s.exports == nil {
		s.exports = map[string]auditExport{}
	}
	now := time.Now()
	for token, e := range s.exports {
		if !now.Before(e.Expires) {
			delete(s.exports, token)
		}
	}
	if len(s.exports) >= 32 {
		return nil, errors.New("too many pending exports; finish or wait for an earlier export to expire")
	}
	events := s.listLocked(ids)
	selected := map[string]bool{}
	for _, e := range events {
		selected[e["id"].(string)] = true
	}
	token, err := auditID()
	if err != nil {
		return nil, err
	}
	s.exports[token] = auditExport{IDs: selected, Key: key, Device: device, Expires: now.Add(15 * time.Minute)}
	return map[string]any{"ok": true, "format": "vortex-owner-audit", "version": 1, "events": events, "retention": auditRetention, "exportedAt": now.UTC(), "snapshotToken": token}, nil
}
func (s *auditStore) confirmExport(token, key, device string, saved bool) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.exports[token]
	if !saved {
		return 0, errors.New("local save must succeed before deleting exported events")
	}
	if !ok || !time.Now().Before(e.Expires) || e.Key != key || e.Device != device {
		return 0, errors.New("export confirmation expired or does not belong to this device")
	}
	if err := s.loadLocked(); err != nil {
		return 0, err
	}
	removed, err := s.clearLocked(e.IDs)
	if err == nil {
		delete(s.exports, token)
	}
	return removed, err
}
func audit(r *http.Request, k *Key, action string, code int) {
	clip := func(s string, n int) string {
		if len(s) > n {
			return s[:n]
		}
		return s
	}
	e := map[string]any{"t": time.Now().Unix(), "ip": clip(clientIP(r), 128), "method": clip(r.Method, 16), "path": clip(r.URL.Path, 2048), "action": clip(action, 128)}
	if k != nil {
		e["key"] = clip(k.ID, 128)
		e["name"] = clip(k.Name, 512)
	}
	if code != 0 {
		e["code"] = code
	}
	if err := ownerAudit.append(e); err != nil {
		log.Printf("owner audit could not be saved: %v", err)
	}
}
func auditIDs(in map[string]any) (map[string]bool, error) {
	values, ok := in["ids"].([]any)
	if !ok || len(values) > auditRetention {
		return nil, errors.New("provide at most 10 displayed event IDs")
	}
	ids := map[string]bool{}
	for _, v := range values {
		id, ok := v.(string)
		if !ok || len(id) != 32 {
			return nil, errors.New("invalid event ID")
		}
		if _, err := hex.DecodeString(id); err != nil {
			return nil, errors.New("invalid event ID")
		}
		ids[id] = true
	}
	return ids, nil
}
func handleAuditAdmin(w http.ResponseWriter, r *http.Request, p string, caller *Key) bool {
	if p != "/admin/audit" && p != "/admin/audit/clear" && p != "/admin/audit/export" && p != "/admin/audit/export/confirm" {
		return false
	}
	if caller == nil || !caller.Admin {
		errJSON(w, 401, "admin key required")
		return true
	}
	if refuseIfBanned(w, r) {
		return true
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if p == "/admin/audit" && r.Method == http.MethodGet {
		events, err := ownerAudit.list()
		if err != nil {
			errJSON(w, 500, err.Error())
		} else {
			json.NewEncoder(w).Encode(map[string]any{"events": events, "retention": auditRetention})
		}
		return true
	}
	if r.Method != http.MethodPost || p == "/admin/audit" {
		errJSON(w, 405, "method not allowed")
		return true
	}
	if !requireOwner(w, r) {
		return true
	}
	var in map[string]any
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	err := dec.Decode(&in)
	var extra any
	if err != nil || in == nil || dec.Decode(&extra) != io.EOF {
		errJSON(w, 400, "invalid bounded JSON object")
		return true
	}
	var removed int
	switch p {
	case "/admin/audit/clear", "/admin/audit/export":
		ids, e := auditIDs(in)
		if e != nil {
			errJSON(w, 400, e.Error())
			return true
		}
		if p == "/admin/audit/export" {
			out, e := ownerAudit.prepareExport(ids, caller.ID, deviceFrom(r))
			if e != nil {
				errJSON(w, 500, e.Error())
			} else {
				json.NewEncoder(w).Encode(out)
			}
			return true
		}
		removed, err = ownerAudit.clear(ids)
	case "/admin/audit/export/confirm":
		token, _ := in["snapshotToken"].(string)
		saved, _ := in["saved"].(bool)
		removed, err = ownerAudit.confirmExport(token, caller.ID, deviceFrom(r), saved)
	}
	if err != nil {
		errJSON(w, 400, err.Error())
		return true
	}
	events, err := ownerAudit.list()
	if err != nil {
		errJSON(w, 500, err.Error())
		return true
	}
	json.NewEncoder(w).Encode(map[string]any{"ok": true, "removed": removed, "events": events, "retention": auditRetention})
	return true
}
