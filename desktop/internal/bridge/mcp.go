package bridge

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type mcpDefinition struct {
	ID                 string   `json:"id"`
	Name               string   `json:"name"`
	Type               string   `json:"type"`
	Command            string   `json:"command,omitempty"`
	Args               []string `json:"args,omitempty"`
	URL                string   `json:"url,omitempty"`
	Enabled            bool     `json:"enabled"`
	AuthMode           string   `json:"authMode,omitempty"`
	KeyName            string   `json:"keyName,omitempty"`
	WorkingDirectory   string   `json:"workingDirectory,omitempty"`
	ConnectTimeout     int      `json:"connectTimeout,omitempty"`
	CallTimeout        int      `json:"callTimeout,omitempty"`
	ProtocolVersion    string   `json:"protocolVersion,omitempty"`
	AutoConnect        *bool    `json:"autoConnect,omitempty"`
	InheritEnvironment bool     `json:"inheritEnvironment,omitempty"`
	SecretReference    string   `json:"secretReference,omitempty"`
	HasKey             bool     `json:"hasKey"`
}
type mcpSecrets struct {
	APIKey      string            `json:"apiKey"`
	Headers     map[string]string `json:"headers"`
	Environment map[string]string `json:"environment"`
}
type mcpConnection struct {
	mu               sync.Mutex
	def              mcpDefinition
	secrets          mcpSecrets
	id               int
	session, version string
	client           *http.Client
	proc             *exec.Cmd
	stdin            io.WriteCloser
	stdout           *bufio.Scanner
	cancel           context.CancelFunc
	tools            []map[string]any
}

var mcpID = regexp.MustCompile(`^[a-z0-9-]{1,64}$`)
var mcpHeader = regexp.MustCompile("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
var mcpEnv = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var mcpReserved = map[string]bool{"host": true, "content-type": true, "accept": true, "content-length": true, "connection": true, "cookie": true, "mcp-session-id": true, "mcp-protocol-version": true, "transfer-encoding": true}

func mcpVersion(v string) bool {
	return v == "2025-11-25" || v == "2025-06-18" || v == "2025-03-26" || v == "2024-11-05"
}
func mcpValid(d mcpDefinition, s mcpSecrets) error {
	if !mcpID.MatchString(d.ID) || strings.TrimSpace(d.Name) == "" {
		return errors.New("server name and ID are required")
	}
	if d.Type == "http" {
		u, e := url.Parse(d.URL)
		if e != nil || u.Host == "" || u.User != nil || u.Fragment != "" {
			return errors.New("invalid MCP endpoint")
		}
		local := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"
		if u.Scheme != "https" && !(u.Scheme == "http" && local) {
			return errors.New("remote MCP requires HTTPS; HTTP is allowed only on localhost")
		}
		for k := range u.Query() {
			switch strings.ToLower(k) {
			case "key", "api_key", "apikey", "token", "access_token", "authorization":
				return errors.New("put credentials in the API-key field, not the URL")
			}
		}
		if d.AuthMode == "environment" {
			return errors.New("environment authentication requires a local command")
		}
	} else if d.Type == "stdio" {
		if strings.TrimSpace(d.Command) == "" || strings.ContainsRune(d.Command, 0) {
			return errors.New("command is required")
		}
		if d.AuthMode != "" && d.AuthMode != "none" && d.AuthMode != "environment" {
			return errors.New("local MCP accepts API keys through environment variables")
		}
	} else {
		return errors.New("unsupported MCP transport")
	}
	switch d.AuthMode {
	case "", "none", "bearer", "header", "environment":
	default:
		return errors.New("unsupported authentication mode")
	}
	if len(s.APIKey) > 4096 || strings.ContainsAny(s.APIKey, "\r\n\x00") {
		return errors.New("invalid API key")
	}
	if len(s.Headers) > 64 || len(s.Environment) > 128 || len(d.Args) > 128 {
		return errors.New("too many optional settings")
	}
	for k, v := range s.Headers {
		if !mcpHeader.MatchString(k) || mcpReserved[strings.ToLower(k)] || strings.ContainsAny(v, "\r\n\x00") || len(v) > 8192 {
			return errors.New("invalid or protocol-reserved header")
		}
	}
	for k, v := range s.Environment {
		if !mcpEnv.MatchString(k) || strings.ContainsRune(v, 0) || len(v) > 32768 {
			return errors.New("invalid environment variable")
		}
	}
	if d.AuthMode == "header" && (!mcpHeader.MatchString(d.KeyName) || mcpReserved[strings.ToLower(d.KeyName)]) {
		return errors.New("invalid API-key header name")
	}
	if d.AuthMode == "environment" && !mcpEnv.MatchString(d.KeyName) {
		return errors.New("API-key environment variable name required")
	}
	for _, n := range []int{d.ConnectTimeout, d.CallTimeout} {
		if n < 0 || n > 3600 {
			return errors.New("timeouts must be 1–3600 seconds or blank")
		}
	}
	if d.ProtocolVersion != "" && !mcpVersion(d.ProtocolVersion) {
		return errors.New("unsupported MCP protocol version")
	}
	if d.WorkingDirectory != "" {
		st, e := os.Stat(d.WorkingDirectory)
		if e != nil || !st.IsDir() || !filepath.IsAbs(d.WorkingDirectory) {
			return errors.New("working directory must be an existing absolute directory")
		}
	}
	return nil
}
func (s *Server) mcpDefinitions() ([]mcpDefinition, error) {
	var defs []mcpDefinition
	b, e := os.ReadFile(filepath.Join(s.St.Dir, "mcp.json"))
	if os.IsNotExist(e) {
		return []mcpDefinition{}, nil
	}
	if e != nil {
		return nil, e
	}
	e = json.Unmarshal(b, &defs)
	return defs, e
}
func (s *Server) mcpSecret(d mcpDefinition) (mcpSecrets, error) {
	if d.SecretReference == "" {
		return mcpSecrets{}, nil
	}
	raw := s.secretGet("mcp-" + d.SecretReference)
	var value mcpSecrets
	if raw == "" || json.Unmarshal([]byte(raw), &value) != nil {
		return value, errors.New("this account's MCP credentials are unavailable; edit and save the connection")
	}
	return value, nil
}
func (s *Server) mcpSave(in map[string]any) map[string]any {
	s.mcpConfigMu.Lock()
	defer s.mcpConfigMu.Unlock()
	raw, _ := json.Marshal(in["server"])
	var d mcpDefinition
	if json.Unmarshal(raw, &d) != nil {
		return map[string]any{"ok": false, "error": "invalid MCP configuration"}
	}
	defs, e := s.mcpDefinitions()
	if e != nil {
		return map[string]any{"ok": false, "error": "saved MCP configuration cannot be read"}
	}
	var sec mcpSecrets
	var old mcpDefinition
	for _, v := range defs {
		if v.ID == d.ID {
			old = v
			sec, e = s.mcpSecret(v)
			if e != nil {
				return map[string]any{"ok": false, "error": e.Error()}
			}
		}
	}
	if k, ok := in["apiKey"].(string); ok && k != "" {
		sec.APIKey = strings.TrimSpace(k)
	}
	if in["clearKey"] == true {
		sec.APIKey = ""
	}
	for name, target := range map[string]*map[string]string{"headers": &sec.Headers, "environment": &sec.Environment} {
		if value, ok := in[name]; ok {
			b, _ := json.Marshal(value)
			if json.Unmarshal(b, target) != nil {
				return map[string]any{"ok": false, "error": "headers and environment must be JSON objects with string values"}
			}
		}
	}
	if e = mcpValid(d, sec); e != nil {
		return map[string]any{"ok": false, "error": e.Error()}
	}
	// References come from the existing record or a new random value, never
	// from a client-supplied pointer into another stored credential.
	d.SecretReference = ""
	d.HasKey = sec.APIKey != ""
	if sec.APIKey != "" || len(sec.Headers) > 0 || len(sec.Environment) > 0 {
		d.SecretReference = randHex(18)
		secret, _ := json.Marshal(sec)
		if e = s.secretSet("mcp-"+d.SecretReference, string(secret)); e != nil {
			return map[string]any{"ok": false, "error": "secure credential storage is unavailable; settings were not replaced"}
		}
	}
	found := false
	for i := range defs {
		if defs[i].ID == d.ID {
			defs[i] = d
			found = true
		}
	}
	if !found {
		defs = append(defs, d)
	}
	b, _ := json.MarshalIndent(defs, "", "  ")
	file := filepath.Join(s.St.Dir, "mcp.json")
	tmp := file + "." + randHex(6)
	if e = os.WriteFile(tmp, b, 0600); e == nil {
		e = os.Rename(tmp, file)
	}
	if e != nil {
		_ = os.Remove(tmp)
		_ = s.secretSet("mcp-"+d.SecretReference, "")
		return map[string]any{"ok": false, "error": "could not save MCP configuration"}
	}
	if old.SecretReference != "" {
		_ = s.secretSet("mcp-"+old.SecretReference, "")
	}
	s.mcpDisconnect(d.ID)
	return map[string]any{"ok": true}
}
func (s *Server) mcpDisconnect(id string) {
	s.mcpMu.Lock()
	c := s.mcpConnections[id]
	delete(s.mcpConnections, id)
	s.mcpMu.Unlock()
	if c != nil {
		c.stop()
	}
}
func (s *Server) stopMCPConnections() {
	s.mcpMu.Lock()
	all := s.mcpConnections
	s.mcpConnections = nil
	s.mcpMu.Unlock()
	for _, c := range all {
		c.stop()
	}
}
func (c *mcpConnection) stop() {
	if c.cancel != nil {
		c.cancel()
	}
	if c.stdin != nil {
		_ = c.stdin.Close()
	}
	if c.proc != nil && c.proc.Process != nil {
		_ = c.proc.Process.Kill()
	}
	if c.client != nil {
		c.client.CloseIdleConnections()
	}
}
func (c *mcpConnection) exchange(ctx context.Context, method string, params any, notification bool) (map[string]any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.id++
	msg := map[string]any{"jsonrpc": "2.0", "method": method, "params": params}
	if !notification {
		msg["id"] = c.id
	}
	raw, _ := json.Marshal(msg)
	matching := func(b []byte) (map[string]any, error) {
		var m map[string]any
		if json.Unmarshal(b, &m) != nil {
			return nil, nil
		}
		if m["id"] != float64(c.id) {
			return nil, nil
		}
		if m["error"] != nil {
			return nil, errors.New("MCP server rejected the request; check credentials, scope and tool arguments")
		}
		out, _ := m["result"].(map[string]any)
		return out, nil
	}
	if c.def.Type == "stdio" {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		done := make(chan struct{})
		defer close(done)
		go func() {
			select {
			case <-ctx.Done():
				c.stop()
			case <-done:
			}
		}()
		if _, e := c.stdin.Write(append(raw, '\n')); e != nil {
			return nil, errors.New("MCP command input failed")
		}
		if notification {
			return nil, nil
		}
		for c.stdout.Scan() {
			if r, e := matching(c.stdout.Bytes()); r != nil || e != nil {
				return r, e
			}
		}
		return nil, errors.New("MCP command exited or exceeded its output limit")
	}
	req, e := http.NewRequestWithContext(ctx, "POST", c.def.URL, bytes.NewReader(raw))
	if e != nil {
		return nil, e
	}
	for k, v := range c.secrets.Headers {
		req.Header.Set(k, v)
	}
	if c.secrets.APIKey != "" {
		switch c.def.AuthMode {
		case "bearer":
			req.Header.Set("Authorization", "Bearer "+c.secrets.APIKey)
		case "header":
			req.Header.Set(c.def.KeyName, c.secrets.APIKey)
		}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("MCP-Protocol-Version", c.version)
	if c.session != "" {
		req.Header.Set("MCP-Session-Id", c.session)
	}
	response, e := c.client.Do(req)
	if e != nil {
		return nil, errors.New("MCP connection failed or timed out; check the endpoint and network")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("MCP HTTP %d: check endpoint, API key and permissions; redirects are not followed", response.StatusCode)
	}
	if session := response.Header.Get("MCP-Session-Id"); session != "" {
		if len(session) > 1024 || strings.ContainsAny(session, "\r\n\x00") {
			return nil, errors.New("invalid MCP session")
		}
		c.session = session
	}
	if notification {
		return nil, nil
	}
	if strings.Contains(strings.ToLower(response.Header.Get("Content-Type")), "text/event-stream") {
		scan := bufio.NewScanner(io.LimitReader(response.Body, 4<<20))
		scan.Buffer(make([]byte, 4096), 4<<20)
		var lines []string
		for scan.Scan() {
			line := scan.Text()
			if line == "" {
				if len(lines) > 0 {
					if r, e := matching([]byte(strings.Join(lines, "\n"))); r != nil || e != nil {
						return r, e
					}
				}
				lines = nil
			} else if strings.HasPrefix(line, "data:") {
				lines = append(lines, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
			}
		}
		if len(lines) > 0 {
			if r, e := matching([]byte(strings.Join(lines, "\n"))); r != nil || e != nil {
				return r, e
			}
		}
	} else {
		b, e := io.ReadAll(io.LimitReader(response.Body, (4<<20)+1))
		if e != nil || len(b) > 4<<20 {
			return nil, errors.New("MCP response exceeded limit")
		}
		if r, e := matching(b); r != nil || e != nil {
			return r, e
		}
	}
	return nil, errors.New("MCP server returned no matching JSON-RPC response")
}
func startMCP(d mcpDefinition, sec mcpSecrets) (*mcpConnection, error) {
	if e := mcpValid(d, sec); e != nil {
		return nil, e
	}
	c := &mcpConnection{def: d, secrets: sec, version: d.ProtocolVersion, client: &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	if c.version == "" {
		c.version = "2025-11-25"
	}
	if d.Type == "stdio" {
		ctx, cancel := context.WithCancel(context.Background())
		c.cancel = cancel
		c.proc = exec.CommandContext(ctx, d.Command, d.Args...)
		c.proc.Dir = d.WorkingDirectory
		env := map[string]string{}
		for _, item := range os.Environ() {
			parts := strings.SplitN(item, "=", 2)
			k := parts[0]
			if d.InheritEnvironment || strings.EqualFold(k, "PATH") || k == "HOME" || k == "USERPROFILE" || k == "SystemRoot" || k == "WINDIR" || k == "TEMP" || k == "TMP" {
				env[k] = parts[1]
			}
		}
		for k, v := range sec.Environment {
			env[k] = v
		}
		if d.AuthMode == "environment" && sec.APIKey != "" {
			env[d.KeyName] = sec.APIKey
		}
		for k, v := range env {
			c.proc.Env = append(c.proc.Env, k+"="+v)
		}
		var e error
		c.stdin, e = c.proc.StdinPipe()
		if e != nil {
			cancel()
			return nil, e
		}
		out, e := c.proc.StdoutPipe()
		if e != nil {
			cancel()
			return nil, e
		}
		c.stdout = bufio.NewScanner(out)
		c.stdout.Buffer(make([]byte, 4096), 4<<20)
		c.proc.Stderr = io.Discard
		if e = c.proc.Start(); e != nil {
			cancel()
			return nil, errors.New("could not launch MCP command; check executable and arguments")
		}
		go c.proc.Wait()
	}
	timeout := d.ConnectTimeout
	if timeout == 0 {
		timeout = 60
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	init, e := c.exchange(ctx, "initialize", map[string]any{"protocolVersion": c.version, "capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "Red-XAI Vortex", "version": "2.12.1"}}, false)
	if e != nil {
		c.stop()
		return nil, e
	}
	version, _ := init["protocolVersion"].(string)
	if !mcpVersion(version) {
		c.stop()
		return nil, errors.New("unsupported server protocol")
	}
	c.version = version
	if _, e = c.exchange(ctx, "notifications/initialized", map[string]any{}, true); e != nil {
		c.stop()
		return nil, e
	}
	cursor := ""
	seen := map[string]bool{}
	for {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		r, e := c.exchange(ctx, "tools/list", params, false)
		if e != nil {
			c.stop()
			return nil, e
		}
		list, _ := r["tools"].([]any)
		for _, v := range list {
			if t, ok := v.(map[string]any); ok {
				c.tools = append(c.tools, t)
			}
		}
		cursor, _ = r["nextCursor"].(string)
		if len(c.tools) > 4096 || seen[cursor] {
			c.stop()
			return nil, errors.New("invalid tool pagination")
		}
		if cursor == "" {
			break
		}
		seen[cursor] = true
	}
	return c, nil
}
func (s *Server) mcpAction(method string, in map[string]any) map[string]any {
	if method == "mcp.import" {
		config, _ := in["config"].(map[string]any)
		entries, _ := config["mcpServers"].(map[string]any)
		if entries == nil {
			entries, _ = config["servers"].(map[string]any)
		}
		if len(entries) == 0 || len(entries) > 100 {
			return map[string]any{"ok": false, "error": "Import requires 1–100 MCP server definitions"}
		}
		imported := 0
		problems := []string{}
		for name, value := range entries {
			original, ok := value.(map[string]any)
			if !ok {
				problems = append(problems, name+": invalid configuration")
				continue
			}
			kind := "stdio"
			if str(original, "url") != "" {
				kind = "http"
			}
			def := map[string]any{"id": "import-" + randHex(10), "name": name, "type": kind, "url": original["url"], "command": original["command"], "args": original["args"], "enabled": false, "authMode": "none"}
			for _, k := range []string{"url", "command"} {
				if def[k] == nil {
					def[k] = ""
				}
			}
			if def["args"] == nil {
				def["args"] = []string{}
			}
			input := map[string]any{"server": def}
			if h, ok := original["headers"]; ok {
				input["headers"] = h
			}
			if env, ok := original["env"]; ok {
				input["environment"] = env
			}
			result := s.mcpSave(input)
			if result["ok"] == true {
				imported++
			} else {
				problems = append(problems, name+": "+fmt.Sprint(result["error"]))
			}
		}
		return map[string]any{"ok": len(problems) == 0, "imported": imported, "errors": problems, "message": fmt.Sprintf("Imported %d connection(s), disabled until you enable them. Existing connections were kept.", imported)}
	}

	if method == "mcp.save" {
		return s.mcpSave(in)
	}
	defs, e := s.mcpDefinitions()
	if e != nil {
		return map[string]any{"ok": false, "error": "cannot read MCP settings"}
	}
	if method == "mcp.list" {
		return map[string]any{"ok": true, "servers": defs}
	}
	id := str(in, "id")
	var d *mcpDefinition
	for i := range defs {
		if defs[i].ID == id {
			d = &defs[i]
			break
		}
	}
	if d == nil {
		return map[string]any{"ok": false, "error": "unknown MCP server in this account"}
	}
	if method == "mcp.disconnect" {
		s.mcpDisconnect(id)
		return map[string]any{"ok": true}
	}
	if method == "mcp.delete" {
		s.mcpDisconnect(id)
		keep := []mcpDefinition{}
		for _, v := range defs {
			if v.ID != id {
				keep = append(keep, v)
			}
		}
		b, _ := json.Marshal(keep)
		if os.WriteFile(filepath.Join(s.St.Dir, "mcp.json"), b, 0600) != nil {
			return map[string]any{"ok": false, "error": "could not remove configuration"}
		}
		if d.SecretReference != "" {
			_ = s.secretSet("mcp-"+d.SecretReference, "")
		}
		return map[string]any{"ok": true}
	}
	if method == "mcp.connect" || method == "mcp.test" {
		sec, e := s.mcpSecret(*d)
		if e != nil {
			return map[string]any{"ok": false, "error": e.Error()}
		}
		c, e := startMCP(*d, sec)
		if e != nil {
			return map[string]any{"ok": false, "error": e.Error()}
		}
		if !s.profileLive() {
			c.stop()
			return map[string]any{"ok": false, "error": "account changed while connecting"}
		}
		if method == "mcp.test" {
			c.stop()
		} else {
			s.mcpDisconnect(id)
			s.mcpMu.Lock()
			if s.mcpConnections == nil {
				s.mcpConnections = map[string]*mcpConnection{}
			}
			s.mcpConnections[id] = c
			s.mcpMu.Unlock()
		}
		return map[string]any{"ok": true, "tools": c.tools, "message": "Initialization and tool discovery succeeded. No tool was executed."}
	}
	return map[string]any{"ok": false, "error": "unsupported MCP action"}
}

// MCP tools enter the existing agent approval loop. Missing/unclear read-only
// annotations are treated as write-capable, never as automatic permission.
func (s *Server) mcpAgentTools(agent store.Agent) []tool {
	if !agent.ToolsOn {
		return nil
	}
	enabled := agent.Permissions == nil
	for _, p := range agent.Permissions {
		if p == "plugins" {
			enabled = true
		}
	}
	if !enabled {
		return nil
	}
	defs, err := s.mcpDefinitions()
	if err != nil {
		return nil
	}
	out := []tool{}
	for _, d := range defs {
		if !d.Enabled {
			continue
		}
		s.mcpMu.Lock()
		connection := s.mcpConnections[d.ID]
		s.mcpMu.Unlock()
		if connection == nil && (d.AutoConnect == nil || *d.AutoConnect) && s.profileLive() {
			if result := s.mcpAction("mcp.connect", map[string]any{"id": d.ID}); result["ok"] == true {
				s.mcpMu.Lock()
				connection = s.mcpConnections[d.ID]
				s.mcpMu.Unlock()
			}
		}
		if connection == nil {
			continue
		}
		c := connection
		for _, t := range c.tools {
			toolName, _ := t["name"].(string)
			if toolName == "" {
				continue
			}
			name := "mcp_" + d.ID + "_" + toolName
			description, _ := t["description"].(string)
			schema, _ := json.Marshal(t["inputSchema"])
			ann, _ := t["annotations"].(map[string]any)
			write := ann["readOnlyHint"] != true || ann["destructiveHint"] == true
			timeout := d.CallTimeout
			if timeout == 0 {
				timeout = 300
			}
			out = append(out, tool{name: name, args: string(schema), desc: description, write: write, run: func(ctx context.Context, args map[string]any) (string, error) {
				if !s.profileLive() {
					return "", errors.New("account changed; MCP action cancelled")
				}
				bounded, cancel := context.WithTimeout(ctx, time.Duration(timeout)*time.Second)
				defer cancel()
				r, e := c.exchange(bounded, "tools/call", map[string]any{"name": toolName, "arguments": args}, false)
				if e != nil {
					return "", e
				}
				b, e := json.Marshal(r)
				return string(b), e
			}})
		}
	}
	return out
}
