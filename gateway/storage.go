package main

// Offload storage for Vortex training data. When disk use on / reaches offload_pct (default 80%),
// closed dataset files and exports are sealed (AEAD from the linked crypto backend, i.e. rsx in
// production) and uploaded to the configured backend, verified, then removed locally.
// Backends: s3 (any S3-compatible: Vultr Object Storage, R2, B2, MinIO, AWS), webdav, terabox (see docs).

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type StorageBackend interface {
	Put(name string, data []byte) error
	Get(name string) ([]byte, error)
	Delete(name string) error
}

type StorageCfg struct {
	Kind         string `json:"kind"` // "" | s3 | webdav | terabox
	Endpoint     string `json:"endpoint"`
	Region       string `json:"region"`
	Bucket       string `json:"bucket"`
	Prefix       string `json:"prefix"`
	AccessKey    string `json:"access_key"`
	Username     string `json:"username"`
	SecretSealed string `json:"secret_sealed,omitempty"`
}

var stMu sync.Mutex

const stFile = "/etc/dolphin/gateway/storage.json"

func stLoad() StorageCfg {
	var c StorageCfg
	if b, err := os.ReadFile(stFile); err == nil {
		json.Unmarshal(b, &c)
	}
	return c
}

func stBackend() (StorageBackend, error) {
	c := stLoad()
	sec := ""
	if c.SecretSealed != "" {
		s, err := openSecret(&Provider{ID: "storage", Sealed: c.SecretSealed})
		if err != nil {
			return nil, errors.New("cannot unseal storage secret")
		}
		sec = s
	}
	switch c.Kind {
	case "s3":
		return &s3B{c, sec}, nil
	case "webdav":
		return &davB{c, sec}, nil
	case "terabox":
		return nil, errors.New("terabox: requires an approved TeraBox Open Platform app (app id/key + OAuth token) and MD5 shard lists; not enabled in this build, use s3 or webdav")
	}
	return nil, errors.New("no storage backend configured")
}

// ---------- S3 (SigV4, hashes/HMAC from the crypto backend) ----------
type s3B struct {
	c   StorageCfg
	sec string
}

func hx(b [32]byte) string { return hex.EncodeToString(b[:]) }

func (s *s3B) do(method, name string, body []byte) (*http.Response, error) {
	u, err := url.Parse(strings.TrimRight(s.c.Endpoint, "/"))
	if err != nil {
		return nil, err
	}
	key := strings.Trim(s.c.Prefix+"/"+name, "/")
	path := "/" + s.c.Bucket + "/" + (&url.URL{Path: key}).EscapedPath()
	reg := s.c.Region
	if reg == "" {
		reg = "us-east-1"
	}
	now := time.Now().UTC()
	amz, day := now.Format("20060102T150405Z"), now.Format("20060102")
	ph := hx(cbSHA256(body))
	canon := strings.Join([]string{method, path, "", "host:" + u.Host, "x-amz-content-sha256:" + ph, "x-amz-date:" + amz, "", "host;x-amz-content-sha256;x-amz-date", ph}, "\n")
	scope := day + "/" + reg + "/s3/aws4_request"
	sts := "AWS4-HMAC-SHA256\n" + amz + "\n" + scope + "\n" + hx(cbSHA256([]byte(canon)))
	k := cbHMAC([]byte("AWS4"+s.sec), []byte(day))
	k = cbHMAC(k[:], []byte(reg))
	k = cbHMAC(k[:], []byte("s3"))
	k = cbHMAC(k[:], []byte("aws4_request"))
	sig := cbHMAC(k[:], []byte(sts))
	req, _ := http.NewRequest(method, u.Scheme+"://"+u.Host+path, bytes.NewReader(body))
	req.Header.Set("x-amz-date", amz)
	req.Header.Set("x-amz-content-sha256", ph)
	req.Header.Set("Authorization", fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s", s.c.AccessKey, scope, hx(sig)))
	return (&http.Client{Timeout: 10 * time.Minute}).Do(req)
}
func (s *s3B) Put(n string, d []byte) error { return okResp(s.do("PUT", n, d)) }
func (s *s3B) Delete(n string) error        { return okResp(s.do("DELETE", n, nil)) }
func (s *s3B) Get(n string) ([]byte, error) { return bodyResp(s.do("GET", n, nil)) }

// ---------- WebDAV ----------
type davB struct {
	c   StorageCfg
	sec string
}

func (d *davB) do(method, name string, body []byte) (*http.Response, error) {
	if !strings.HasPrefix(d.c.Endpoint, "https://") {
		return nil, errors.New("webdav endpoint must be https")
	}
	u := strings.TrimRight(d.c.Endpoint, "/") + "/" + strings.Trim(d.c.Prefix+"/"+name, "/")
	req, _ := http.NewRequest(method, u, bytes.NewReader(body))
	req.SetBasicAuth(d.c.Username, d.sec)
	return (&http.Client{Timeout: 10 * time.Minute}).Do(req)
}
func (d *davB) Put(n string, b []byte) error { return okResp(d.do("PUT", n, b)) }
func (d *davB) Delete(n string) error        { return okResp(d.do("DELETE", n, nil)) }
func (d *davB) Get(n string) ([]byte, error) { return bodyResp(d.do("GET", n, nil)) }

func okResp(r *http.Response, err error) error {
	if err != nil {
		return err
	}
	io.Copy(io.Discard, r.Body)
	r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("storage HTTP %d", r.StatusCode)
	}
	return nil
}
func bodyResp(r *http.Response, err error) ([]byte, error) {
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return nil, fmt.Errorf("storage HTTP %d", r.StatusCode)
	}
	return io.ReadAll(io.LimitReader(r.Body, 4<<30))
}

// ---------- offload ----------
type offRec struct {
	Name   string `json:"name"`
	Remote string `json:"remote"`
	Bytes  int64  `json:"bytes"`
	At     int64  `json:"at"`
}

func offIndexPath() string { return filepath.Join(rxDir, "offloaded.json") }
func offIndex() []offRec {
	var x []offRec
	if b, err := os.ReadFile(offIndexPath()); err == nil {
		json.Unmarshal(b, &x)
	}
	return x
}

func diskPct(path string) int {
	var s syscall.Statfs_t
	if syscall.Statfs(path, &s) != nil || s.Blocks == 0 {
		return 0
	}
	return int(100 - (s.Bavail*100)/s.Blocks)
}

func offloadCandidates() []string {
	cur := "feedback-" + time.Now().Format("200601") + ".rxds"
	var out []string
	ds, _ := filepath.Glob(filepath.Join(rxDir, "datasets", "*.rxds"))
	for _, f := range ds {
		if filepath.Base(f) != cur {
			out = append(out, f)
		}
	}
	ex, _ := filepath.Glob(filepath.Join(rxDir, "export", "*.jsonl"))
	out = append(out, ex...)
	sort.Strings(out)
	return out
}

func runOffload(force bool) (map[string]any, error) {
	stMu.Lock()
	defer stMu.Unlock()
	pct, lim := diskPct("/"), rxConfig().OffloadPct
	if lim <= 0 {
		lim = 80
	}
	if !force && pct < lim {
		return map[string]any{"ok": true, "disk_pct": pct, "threshold": lim, "moved": 0}, nil
	}
	be, err := stBackend()
	if err != nil {
		return nil, err
	}
	idx := offIndex()
	moved := 0
	for _, f := range offloadCandidates() {
		pt, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		rel, _ := filepath.Rel(rxDir, f)
		remote := strings.ReplaceAll(rel, "/", "_") + "." + time.Now().Format("20060102150405") + ".vxo"
		sealed, err := rxSeal(pt, "offload:"+remote)
		if err != nil {
			return nil, err
		}
		if err := be.Put(remote, sealed); err != nil {
			return map[string]any{"ok": false, "moved": moved, "error": err.Error()}, nil
		}
		back, err := be.Get(remote)
		if err != nil || !bytes.Equal(back, sealed) {
			return map[string]any{"ok": false, "moved": moved, "error": "verify failed for " + remote}, nil
		}
		os.Remove(f)
		idx = append(idx, offRec{rel, remote, int64(len(pt)), time.Now().Unix()})
		b, _ := json.Marshal(idx)
		os.WriteFile(offIndexPath(), b, 0600)
		moved++
	}
	return map[string]any{"ok": true, "disk_pct": pct, "threshold": lim, "moved": moved}, nil
}

func restoreOffload(remote string) error {
	be, err := stBackend()
	if err != nil {
		return err
	}
	for _, r := range offIndex() {
		if r.Remote == remote {
			b, err := be.Get(remote)
			if err != nil {
				return err
			}
			pt, err := rxOpen(b, "offload:"+remote)
			if err != nil {
				return errors.New("unseal failed")
			}
			dst := filepath.Join(rxDir, r.Name)
			os.MkdirAll(filepath.Dir(dst), 0700)
			return os.WriteFile(dst, pt, 0600)
		}
	}
	return errors.New("unknown remote object")
}

func offloadLoop() {
	for range time.Tick(10 * time.Minute) {
		if stLoad().Kind != "" {
			runOffload(false)
		}
	}
}

func storageAdmin(w http.ResponseWriter, r *http.Request, p string, in map[string]any) bool {
	if !strings.HasPrefix(p, "/admin/storage") {
		return false
	}
	if r.Method != "GET" && !requireOwner(w, r) {
		return true
	}
	switch {
	case p == "/admin/storage" && r.Method == "GET":
		c := stLoad()
		has := c.SecretSealed != ""
		c.SecretSealed = ""
		json.NewEncoder(w).Encode(map[string]any{"config": c, "secret_set": has, "disk_pct": diskPct("/"), "threshold": rxConfig().OffloadPct, "offloaded": offIndex(), "pending": len(offloadCandidates())})
	case p == "/admin/storage" && r.Method == "POST":
		old := stLoad()
		var c StorageCfg
		b, _ := json.Marshal(in)
		json.Unmarshal(b, &c)
		c.SecretSealed = old.SecretSealed
		if s, _ := in["secret"].(string); s != "" {
			sealed, err := sealSecret("storage", s)
			if err != nil {
				errJSON(w, 500, "seal failed")
				return true
			}
			c.SecretSealed = sealed
		}
		if c.Kind != "" && c.Kind != "s3" && c.Kind != "webdav" && c.Kind != "terabox" {
			errJSON(w, 400, "kind must be s3, webdav or terabox")
			return true
		}
		writeJSONPath(stFile, c)
		w.Write([]byte(`{"ok":true}`))
	case p == "/admin/storage/test" && r.Method == "POST":
		be, err := stBackend()
		if err == nil {
			n := "vortex-test-" + randB62(8)
			if err = be.Put(n, []byte("ok")); err == nil {
				var g []byte
				if g, err = be.Get(n); err == nil && string(g) != "ok" {
					err = errors.New("read-back mismatch")
				}
				be.Delete(n)
			}
		}
		if err != nil {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
			return true
		}
		w.Write([]byte(`{"ok":true}`))
	case p == "/admin/storage/offload" && r.Method == "POST":
		force, _ := in["force"].(bool)
		res, err := runOffload(force)
		if err != nil {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
			return true
		}
		json.NewEncoder(w).Encode(res)
	case p == "/admin/storage/restore" && r.Method == "POST":
		rm, _ := in["remote"].(string)
		if err := restoreOffload(rm); err != nil {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
			return true
		}
		w.Write([]byte(`{"ok":true}`))
	default:
		errJSON(w, 404, "not found")
	}
	return true
}
