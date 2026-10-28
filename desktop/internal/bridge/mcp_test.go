package bridge

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMCPBearerSessionPaginationAndToolExecution(t *testing.T) {
	called := false
	initialized := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture-key" {
			t.Error("key header missing")
		}
		if !strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
			t.Error("SSE accept missing")
		}
		var req map[string]any
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			t.Error("bad JSON request")
			return
		}
		method, _ := req["method"].(string)
		if initialized && r.Header.Get("MCP-Session-Id") != "fixture-session" {
			t.Error("MCP session not reused")
		}
		if method == "notifications/initialized" {
			w.WriteHeader(202)
			return
		}
		result := map[string]any{}
		switch method {
		case "initialize":
			initialized = true
			w.Header().Set("MCP-Session-Id", "fixture-session")
			result["protocolVersion"] = "2025-11-25"
		case "tools/list":
			p, _ := req["params"].(map[string]any)
			if p["cursor"] == nil {
				result["tools"] = []any{map[string]any{"name": "search", "inputSchema": map[string]any{"type": "object"}, "annotations": map[string]any{"readOnlyHint": true}}}
				result["nextCursor"] = "next"
			} else {
				result["tools"] = []any{map[string]any{"name": "write", "inputSchema": map[string]any{"type": "object"}}}
			}
		case "tools/call":
			called = true
			result["content"] = []any{map[string]any{"type": "text", "text": "fixture reply"}}
		}
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req["id"], "result": result})
		if method == "tools/list" {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "event: message\ndata: %s\n\n", data)
		} else {
			w.Header().Set("Content-Type", "application/json")
			w.Write(data)
		}
	}))
	defer server.Close()
	d := mcpDefinition{ID: "fixture", Name: "Fixture", Type: "http", URL: server.URL, AuthMode: "bearer", ConnectTimeout: 3}
	c, e := startMCP(d, mcpSecrets{APIKey: "fixture-key"})
	if e != nil {
		t.Fatal(e)
	}
	defer c.stop()
	if len(c.tools) != 2 || called {
		t.Fatal("discovery incorrectly executed tools or lost pagination")
	}
	root := workspaceServer(t)
	root.baseCredential = nil
	p, e := root.activateVerifiedAccount("mcp-owner", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(root.lockAccount)
	if e = p.secretSet("mcp-fixture", `{"apiKey":"fixture-key"}`); e != nil {
		t.Fatal(e)
	}
	d.SecretReference = "fixture"
	d.Enabled = true
	b, _ := json.Marshal([]mcpDefinition{d})
	if e = os.WriteFile(filepath.Join(p.St.Dir, "mcp.json"), b, 0600); e != nil {
		t.Fatal(e)
	}
	p.mcpConnections = map[string]*mcpConnection{d.ID: c}
	agents := p.St.AgentsSnapshot()
	tools := p.mcpAgentTools(agents[0])
	if len(tools) != 2 {
		t.Fatal("MCP tools not offered to authorized agent")
	}
	if tools[0].write || !tools[1].write {
		t.Fatal("MCP write approval classification is unsafe")
	}
}

func TestMCPSecretsStayOutOfPublicConfigurationAndCannotCrossAccounts(t *testing.T) {
	root := workspaceServer(t)
	root.baseCredential = nil
	a, e := root.activateVerifiedAccount("mcp-alice", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(root.lockAccount)
	result := a.mcpSave(map[string]any{"server": map[string]any{"id": "firecrawl", "name": "Firecrawl", "type": "http", "url": "https://mcp.firecrawl.dev/v2/mcp", "authMode": "bearer"}, "apiKey": "fixture-secret-value", "headers": map[string]string{"X-Key": "another-secret"}})
	if result["ok"] != true {
		t.Fatal(result)
	}
	content, e := os.ReadFile(filepath.Join(a.St.Dir, "mcp.json"))
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(string(content), "fixture-secret-value") || strings.Contains(string(content), "another-secret") {
		t.Fatal("secret in public configuration")
	}
	defs, _ := a.mcpDefinitions()
	sec, e := a.mcpSecret(defs[0])
	if e != nil || sec.APIKey != "fixture-secret-value" {
		t.Fatal("stored key missing")
	}
	b, e := root.activateVerifiedAccount("mcp-bob", "", time.Now().Add(time.Hour), root.accountEpoch())
	if e != nil {
		t.Fatal(e)
	}
	if _, e = b.mcpSecret(defs[0]); e == nil {
		t.Fatal("another account loaded Alice credential reference")
	}
}

func TestMCPValidationBlocksCredentialURLsRedirectsAndHeaderInjection(t *testing.T) {
	d := mcpDefinition{ID: "valid", Name: "Valid", Type: "http", URL: "https://example.com/mcp"}
	for _, u := range []string{"http://remote.example/mcp", "https://name:password@example.com/mcp", "https://example.com/mcp?api_key=secret"} {
		v := d
		v.URL = u
		if mcpValid(v, mcpSecrets{}) == nil {
			t.Error("unsafe URL accepted")
		}
	}
	if mcpValid(d, mcpSecrets{Headers: map[string]string{"Host": "other.example"}}) == nil {
		t.Error("reserved header accepted")
	}
	if mcpValid(d, mcpSecrets{Headers: map[string]string{"X-Key": "a\r\nb"}}) == nil {
		t.Error("header injection accepted")
	}
	destinationCalled := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { destinationCalled = true; w.WriteHeader(500) }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer redirect.Close()
	d.URL = redirect.URL
	d.AuthMode = "bearer"
	d.ConnectTimeout = 2
	if _, e := startMCP(d, mcpSecrets{APIKey: "fixture"}); e == nil {
		t.Error("credential redirect was followed")
	}
	if destinationCalled {
		t.Fatal("credential crossed redirect boundary")
	}
}
