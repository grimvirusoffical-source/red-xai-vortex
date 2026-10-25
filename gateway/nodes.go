package main

// Server nodes in the Vortex compute pool (/etc/dolphin/nodes.d/*.env). Each node runs ggml-rpc-server on its own
// 127.0.0.1 and is reached only through an SSH tunnel from this server, so RPC is never public.
// Pooled models (/etc/dolphin/pooled-models.json) get "rpc = <enabled nodes>" in presets via `dolphin-models presets`.

import (
	"bufio"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const nodesDir = "/etc/dolphin/nodes.d"

var nodeNameRE = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)

func readEnvFile(p string) map[string]string {
	m := map[string]string{}
	f, err := os.Open(p)
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if k, v, ok := strings.Cut(l, "="); ok {
			m[k] = strings.Trim(v, `"`)
		}
	}
	return m
}

func listNodes() []map[string]any {
	out := []map[string]any{}
	fs, _ := filepath.Glob(filepath.Join(nodesDir, "*.env"))
	for _, f := range fs {
		e := readEnvFile(f)
		up := false
		if c, err := net.DialTimeout("tcp", e["RPC"], 2*time.Second); err == nil {
			up = true
			c.Close()
		}
		out = append(out, map[string]any{"name": e["NAME"], "kind": e["KIND"], "host": e["HOST"], "label": e["LABEL"],
			"rpc": e["RPC"], "enabled": e["ENABLED"] == "1", "online": up, "in_pool": up && e["ENABLED"] == "1"})
	}
	return out
}

func pooledModels() []map[string]any {
	var x []map[string]any
	if b, err := os.ReadFile("/etc/dolphin/pooled-models.json"); err == nil {
		json.Unmarshal(b, &x)
	}
	return x
}

func nodesAdmin(w http.ResponseWriter, r *http.Request, p string) bool {
	if !strings.HasPrefix(p, "/admin/nodes") {
		return false
	}
	if r.Method != "GET" && !requireOwner(w, r) {
		return true
	}
	switch {
	case p == "/admin/nodes" && r.Method == "GET":
		json.NewEncoder(w).Encode(map[string]any{"nodes": listNodes(), "pooled_models": pooledModels(), "storage": combinedStorage()})
	case strings.HasPrefix(p, "/admin/nodes/") && r.Method == "POST":
		rest := strings.Split(strings.TrimPrefix(p, "/admin/nodes/"), "/")
		if len(rest) != 2 || !nodeNameRE.MatchString(rest[0]) || (rest[1] != "enable" && rest[1] != "disable") {
			errJSON(w, 404, "not found")
			return true
		}
		f := filepath.Join(nodesDir, rest[0]+".env")
		b, err := os.ReadFile(f)
		if err != nil {
			errJSON(w, 404, "no such node")
			return true
		}
		v := "0"
		if rest[1] == "enable" {
			v = "1"
		}
		s := regexp.MustCompile(`(?m)^ENABLED=.*$`).ReplaceAllString(string(b), "ENABLED="+v)
		if err := os.WriteFile(f, []byte(s), 0644); err != nil {
			errJSON(w, 500, "write failed")
			return true
		}
		exec.Command("/usr/local/bin/dolphin-models", "presets").Run()
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "nodes": listNodes()})
	default:
		errJSON(w, 405, "method not allowed")
	}
	return true
}
