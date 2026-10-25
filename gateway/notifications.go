package main

// Notifications feed for every Vortex user.
//   GET  /v1/notifications            → {"unread":N,"data":[...newest first]}
//   POST /v1/notifications/read       {"ids":[...]} or {"all":true}
// Recipients: a key ID, "owner" (all owner/admin keys) or "user:<redx-username>"
// (keys whose name or redx_user matches). Local services (Cloud PC web) post to
// 127.0.0.1:18093/notify, which only listens on loopback.

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type notif struct {
	ID    string `json:"id"`
	To    string `json:"to"`
	Kind  string `json:"kind"` // cloudpc_request|cloudpc_decision|agent|media|merge|distill|update|plugin
	Title string `json:"title"`
	Body  string `json:"body,omitempty"`
	Link  string `json:"link,omitempty"`
	TS    int64  `json:"ts"`
	Read  bool   `json:"read"`
}

var (
	nMu    sync.Mutex
	nList  []*notif
	nReady bool
)

func nPath() string { return filepath.Join(dir, "notifications.json") }

func nLoadLocked() {
	if nReady {
		return
	}
	nReady = true
	if b, err := os.ReadFile(nPath()); err == nil {
		json.Unmarshal(b, &nList)
	}
}

func nSaveLocked() {
	if len(nList) > 2000 {
		nList = nList[len(nList)-2000:]
	}
	b, _ := json.Marshal(nList)
	tmp := nPath() + ".tmp"
	if os.WriteFile(tmp, b, 0600) == nil {
		os.Rename(tmp, nPath())
	}
}

// notify adds a notification. Safe to call from any goroutine.
func notify(to, kind, title, body, link string) {
	if to == "" {
		return
	}
	nMu.Lock()
	defer nMu.Unlock()
	nLoadLocked()
	nList = append(nList, &notif{ID: "nt_" + randB62(10), To: to, Kind: kind, Title: title, Body: trunc(body, 400), Link: link, TS: time.Now().Unix()})
	nSaveLocked()
}

func nFor(k *Key, n *notif) bool {
	if n.To == k.ID {
		return true
	}
	if n.To == "owner" {
		return k.Admin || k.Role == "owner" || k.Role == "admin"
	}
	if u, ok := strings.CutPrefix(n.To, "user:"); ok {
		return strings.EqualFold(u, k.Name)
	}
	return false
}

func handleNotifications(w http.ResponseWriter, r *http.Request, k *Key) {
	nMu.Lock()
	defer nMu.Unlock()
	nLoadLocked()
	w.Header().Set("Content-Type", "application/json")
	if r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/read") {
		var in struct {
			IDs []string `json:"ids"`
			All bool     `json:"all"`
		}
		json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in)
		want := map[string]bool{}
		for _, id := range in.IDs {
			want[id] = true
		}
		c := 0
		for _, n := range nList {
			if nFor(k, n) && !n.Read && (in.All || want[n.ID]) {
				n.Read = true
				c++
			}
		}
		nSaveLocked()
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "marked": c})
		return
	}
	if r.Method != "GET" {
		errJSON(w, 405, "GET or POST /v1/notifications/read")
		return
	}
	out, unread := []*notif{}, 0
	for i := len(nList) - 1; i >= 0; i-- {
		n := nList[i]
		if !nFor(k, n) {
			continue
		}
		if !n.Read {
			unread++
		}
		if len(out) < 200 {
			out = append(out, n)
		}
	}
	json.NewEncoder(w).Encode(map[string]any{"unread": unread, "data": out})
}

func startNotifyLocal() {
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() || r.Method != "POST" {
			http.Error(w, "forbidden", 403)
			return
		}
		var n notif
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&n) != nil || n.To == "" || n.Title == "" {
			http.Error(w, "bad request", 400)
			return
		}
		notify(n.To, n.Kind, n.Title, n.Body, n.Link)
		w.WriteHeader(204)
	})
	go func() {
		s := &http.Server{Addr: "127.0.0.1:18093", Handler: h, ReadHeaderTimeout: 5 * time.Second}
		if err := s.ListenAndServe(); err != nil {
			log.Printf("notify listener: %v", err)
		}
	}()
}
