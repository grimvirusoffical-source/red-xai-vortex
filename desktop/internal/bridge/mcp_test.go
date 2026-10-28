package bridge

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func mcpFixture(t *testing.T, auth string, sse bool) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	calls := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != auth {
			w.WriteHeader(401)
			return
		}
		var m map[string]any
		if json.NewDecoder(r.Body).Decode(&m) != nil {
			w.WriteHeader(400)
			return
		}
		method, _ := m["method"].(string)
		if method != "initialize" {
			if r.Header.Get("MCP-Session-Id") != "fixture-session" || r.Header.Get("MCP-Protocol-Version") != "2025-06-18" {
				w.WriteHeader(400)
				return
			}
		}
		if strings.Contains(fmt.Sprint(m), "fixture-secret") {
			t.Error("API credential leaked into the JSON-RPC body")
		}
		result := map[string]any{}
		switch method {
		case "initialize":
			result["protocolVersion"] = "2025-06-18"
			w.Header().Set("MCP-Session-Id", "fixture-session")
		case "notifications/initialized":
			w.WriteHeader(202)
			return
		case "tools/list":
			params, _ := m["params"].(map[string]any)
			name := "first"
			if params["cursor"] == nil {
				result["nextCursor"] = "page-2"
			} else {
				name = "second"
			}
			result["tools"] = []map[string]any{{"name": name, "description": "fixture tool", "inputSchema": map[string]any{"type": "object"}}}
		case "tools/call":
			calls.Add(1)
			result["content"] = []map[string]any{{"type": "text", "text": "fixture-success"}}
		default:
			w.WriteHeader(400)
			return
		}
		reply := map[string]any{"jsonrpc": "2.0", "id": m["id"], "result": result}
		if sse {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n")
			data, _ := json.Marshal(reply)
			fmt.Fprintf(w, "data: %s\n\n", data)
		} else {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(reply)
		}
	}))
	t.Cleanup(server.Close)
	return server, calls
}
func TestMCPBearerSessionPaginationAndToolExecution(t *testing.T) {
	for _, sse := range []bool{false, true} {
		t.Run(fmt.Sprint(sse), func(t *testing.T) {
			server, calls := mcpFixture(t, "Bearer fixture-secret", sse)
			d := mcpDefinition{ID: "firecrawl", Name: "Fixture", Type: "http", URL: server.URL, AuthMode: "bearer", Enabled: true}
			c, e := startMCP(d, mcpSecrets{APIKey: "fixture-secret"})
			if e != nil {
				t.Fatal(e)
			}
			defer c.stop()
			if len(c.tools) != 2 || calls.Load() != 0 {
				t.Fatal("discovery must paginate without executing tools")
			}
			result, e := c.exchange(context.Background(), "tools/call", map[string]any{"name": "first", "arguments": map[string]any{}}, false)
			if e != nil || !strings.Contains(fmt.Sprint(result), "fixture-success") || calls.Load() != 1 {
				t.Fatalf("tool result: %v %v", result, e)
			}
		})
	}
}
func TestMCPNoAuthBasicAndCustomHeader(t *testing.T) {
	for _, auth := range []string{"none", "basic", "header"} {
		t.Run(auth, func(t *testing.T) {
			wanted := ""
			secret := mcpSecrets{}
			if auth == "basic" {
				wanted = "Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtc2VjcmV0"
				secret = mcpSecrets{Username: "fixture-user", APIKey: "fixture-secret"}
			}
			if auth == "header" {
				wanted = "Bearer fixture-secret"
				secret = mcpSecrets{APIKey: wanted}
			}
			server, _ := mcpFixture(t, wanted, false)
			c, e := startMCP(mcpDefinition{ID: "fixture", Name: "Fixture", Type: "http", URL: server.URL, AuthMode: auth, KeyName: "Authorization"}, secret)
			if e != nil {
				t.Fatal(e)
			}
			c.stop()
		})
	}
}
func TestMCPRejectsUnsafeSettings(t *testing.T) {
	d := mcpDefinition{ID: "fixture", Name: "Fixture", Type: "http", URL: "https://example.com/mcp"}
	if e := mcpValid(d, mcpSecrets{}); e != nil {
		t.Fatal("auth must be optional", e)
	}
	for _, url := range []string{"http://remote.example/mcp", "https://user:pass@example.com/mcp", "https://example.com/mcp?api_key=secret"} {
		copy := d
		copy.URL = url
		if mcpValid(copy, mcpSecrets{}) == nil {
			t.Fatal(url)
		}
	}
	for _, sec := range []mcpSecrets{{Headers: map[string]string{"Host": "evil"}}, {Headers: map[string]string{"X-Test": "x\r\nBad:y"}}, {Headers: map[string]string{"X-Test": "x", "x-test": "y"}}} {
		if mcpValid(d, sec) == nil {
			t.Fatal("unsafe header accepted")
		}
	}
	d.AuthMode = "bearer"
	if mcpValid(d, mcpSecrets{}) == nil {
		t.Fatal("selected bearer auth needs a key")
	}
	if mcpValid(d, mcpSecrets{APIKey: "test", Headers: map[string]string{"Authorization": "duplicate"}}) == nil {
		t.Fatal("duplicate authentication accepted")
	}
}
func TestMCPRedirectDoesNotForwardSecrets(t *testing.T) {
	leaked := atomic.Bool{}
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked.Store(true) }))
	defer destination.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	_, e := startMCP(mcpDefinition{ID: "fixture", Name: "Fixture", Type: "http", URL: origin.URL, AuthMode: "bearer"}, mcpSecrets{APIKey: "fixture-secret"})
	if e == nil || leaked.Load() {
		t.Fatal("credential redirect was followed")
	}
	if strings.Contains(e.Error(), "fixture-secret") {
		t.Fatal("credential leaked through diagnostic")
	}
}
func TestMCPAccountCredentialAndConfigIsolation(t *testing.T) {
	aID, _ := profileIdentifier("mcp-account-a")
	bID, _ := profileIdentifier("mcp-account-b")
	a := &Server{St: store.OpenAt(t.TempDir()), profileID: aID, profileDone: make(chan struct{})}
	b := &Server{St: store.OpenAt(t.TempDir()), profileID: bID, profileDone: make(chan struct{})}
	input := map[string]any{"server": map[string]any{"id": "firecrawl", "name": "Firecrawl", "type": "http", "url": "https://mcp.firecrawl.dev/v2/mcp", "authMode": "bearer", "enabled": true}, "apiKey": "fixture-private-key"}
	if result := a.mcpSave(input); result["ok"] != true {
		t.Fatal(result)
	}
	defer a.mcpAction("mcp.delete", map[string]any{"id": "firecrawl"})
	defs, e := a.mcpDefinitions()
	if e != nil || len(defs) != 1 {
		t.Fatal(e)
	}
	body, _ := os.ReadFile(filepath.Join(a.St.Dir, "mcp.json"))
	if strings.Contains(string(body), "fixture-private-key") {
		t.Fatal("credential in exported JSON")
	}
	if defs, e := b.mcpDefinitions(); e != nil || len(defs) != 0 {
		t.Fatal("B sees A's MCP settings")
	}
	if _, e := b.mcpSecret(defs[0]); e == nil {
		t.Fatal("B can retrieve A's credential reference")
	}
	if len(a.mcpAgentTools(store.Agent{ToolsOn: true})) != 0 {
		t.Fatal("legacy agents must not gain MCP permissions automatically")
	}
}
func TestMCPStopCancelsInFlightAndFutureHTTPRequests(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(entered)
		<-r.Context().Done()
	}))
	defer server.Close()
	life, cancel := context.WithCancel(context.Background())
	c := &mcpConnection{ctx: life, cancel: cancel, client: &http.Client{}, def: mcpDefinition{Type: "http", URL: server.URL}, version: "2025-06-18"}
	done := make(chan error, 1)
	go func() { _, e := c.exchange(context.Background(), "tools/call", map[string]any{}, false); done <- e }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	c.stop()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("cancelled call succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("stop did not cancel request")
	}
	if _, e := c.exchange(context.Background(), "tools/list", nil, false); e == nil {
		t.Fatal("closed connection accepted another request")
	}
}
func TestMCPStdioEnvironment(t *testing.T) {
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	d := mcpDefinition{ID: "fixture", Name: "Fixture", Type: "stdio", Command: exe, Args: []string{"-test.run=^TestMCPStdioHelper$"}, AuthMode: "environment", KeyName: "FIRECRAWL_API_KEY"}
	c, e := startMCP(d, mcpSecrets{APIKey: "fixture-key", Environment: map[string]string{"VORTEX_MCP_TEST_HELPER": "1"}})
	if e != nil {
		t.Fatal(e)
	}
	defer c.stop()
	if len(c.tools) != 1 {
		t.Fatal("stdio tool missing")
	}
}
func TestMCPStdioHelper(t *testing.T) {
	if os.Getenv("VORTEX_MCP_TEST_HELPER") != "1" {
		return
	}
	if os.Getenv("FIRECRAWL_API_KEY") != "fixture-key" {
		os.Exit(4)
	}
	scan := bufio.NewScanner(os.Stdin)
	for scan.Scan() {
		var m map[string]any
		if json.Unmarshal(scan.Bytes(), &m) != nil {
			os.Exit(5)
		}
		if m["id"] == nil {
			continue
		}
		out := map[string]any{}
		switch m["method"] {
		case "initialize":
			out["protocolVersion"] = "2025-06-18"
		case "tools/list":
			out["tools"] = []map[string]any{{"name": "fixture"}}
		default:
			os.Exit(6)
		}
		if json.NewEncoder(os.Stdout).Encode(map[string]any{"jsonrpc": "2.0", "id": m["id"], "result": out}) != nil {
			os.Exit(7)
		}
	}
	os.Exit(0)
}
