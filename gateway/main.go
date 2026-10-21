// dolphin-gateway: OpenAI-compatible key gateway + model admin + merge ensembles for dolphin-llm.
// Crypto: Red-SecretsXAI (rsx) only. Keys stored as HMAC-SHA256(pepper, key); plaintext shown once.
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	upstream  = "http://127.0.0.1:8090"
	dir       = "/etc/dolphin/gateway"
	modelsDir = "/opt/dolphin/models"
	maxBody   = 4 << 20
	maxTokens = 4096
	memBudget = int64(26e9)
	mergePref = "redx-merge-"
)

type Key struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Prefix   string   `json:"prefix"`
	Hash     string   `json:"hash"`
	Models   []string `json:"models"` // empty = all
	RPM      int      `json:"rpm"`
	Admin    bool     `json:"admin,omitempty"`
	Created  int64    `json:"created"`
	LastUsed int64    `json:"last_used"`
	Revoked  int64    `json:"revoked,omitempty"`
	Requests int64    `json:"requests"`
	Tokens   int64    `json:"tokens"`
}

type Merge struct {
	Name   string   `json:"name"`
	Mode   string   `json:"mode"` // draft_refine | panel_judge | router
	Models []string `json:"models"`
	Judge  string   `json:"judge,omitempty"`
	Note   string   `json:"note,omitempty"`
}

var (
	mu      sync.Mutex
	keys    []*Key
	merges  []*Merge
	pepper  []byte
	upKey   string
	gen     = make(chan struct{}, 1) // one generation at a time (CPU box, memory guard)
	buckets = map[string]*bucket{}
	dirty   bool
)

type bucket struct {
	tokens float64
	last   time.Time
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func randB62(n int) string {
	const al = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	out := make([]byte, 0, n)
	for len(out) < n {
		b, err := cbRandom(64)
		must(err)
		for _, c := range b {
			if c < 248 && len(out) < n { // 248 = 62*4, unbiased
				out = append(out, al[int(c)%62])
			}
		}
	}
	return string(out)
}

func hashKey(k string) string {
	h := cbHMAC(pepper, []byte("redx-ai-key-v1\x00"+k))
	return hex.EncodeToString(h[:])
}

func ctEq(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

func load() {
	p, err := os.ReadFile(filepath.Join(dir, "pepper"))
	if errors.Is(err, os.ErrNotExist) {
		p, err = cbRandom(32)
		must(err)
		must(os.WriteFile(filepath.Join(dir, "pepper"), p, 0600))
	} else {
		must(err)
	}
	pepper = p
	b, err := os.ReadFile("/etc/dolphin/api-keys")
	must(err)
	upKey = strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0])
	if b, err := os.ReadFile(filepath.Join(dir, "keys.json")); err == nil {
		must(json.Unmarshal(b, &keys))
	}
	loadProviders()
	if b, err := os.ReadFile(filepath.Join(dir, "merges.json")); err == nil {
		must(json.Unmarshal(b, &merges))
	} else {
		merges = []*Merge{
			{Name: "draft-refine", Mode: "draft_refine", Models: []string{"dolphin3-llama3.2-3b-q4km", "dolphin3-mistral-24b-q6k"}, Note: "3B drafts fast, 24B polishes"},
			{Name: "panel", Mode: "panel_judge", Models: []string{"dolphin3-llama3.1-8b-q8", "qwen2.5-coder-14b", "r1-distill-qwen-14b"}, Judge: "dolphin3-mistral-24b-q6k", Note: "3 models answer, 24B judges and synthesizes"},
			{Name: "auto", Mode: "router", Models: []string{"qwen2.5-coder-14b", "r1-distill-qwen-14b", "dolphin2.7-mixtral-8x7b-iq4xs"}, Note: "code→coder, reasoning→R1, else Mixtral"},
		}
		saveMerges()
	}
}

func writeJSON(name string, v any) {
	b, _ := json.MarshalIndent(v, "", " ")
	tmp := filepath.Join(dir, name+".tmp")
	if os.WriteFile(tmp, b, 0600) == nil {
		os.Rename(tmp, filepath.Join(dir, name))
	}
}
func saveKeys()   { writeJSON("keys.json", keys) }
func saveMerges() { writeJSON("merges.json", merges) }

func auth(r *http.Request) *Key {
	h := r.Header.Get("Authorization")
	k := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	if k == "" {
		k = r.Header.Get("x-api-key")
	}
	if !strings.HasPrefix(k, "redx_ai_") || len(k) > 128 {
		return nil
	}
	hk := hashKey(k)
	mu.Lock()
	defer mu.Unlock()
	for _, x := range keys {
		if x.Revoked == 0 && ctEq(x.Hash, hk) {
			return x
		}
	}
	return nil
}

func allow(k *Key) bool {
	mu.Lock()
	defer mu.Unlock()
	rpm := k.RPM
	if rpm <= 0 {
		rpm = 60
	}
	b := buckets[k.ID]
	now := time.Now()
	if b == nil {
		b = &bucket{tokens: float64(rpm), last: now}
		buckets[k.ID] = b
	}
	b.tokens += now.Sub(b.last).Minutes() * float64(rpm)
	if b.tokens > float64(rpm) {
		b.tokens = float64(rpm)
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	k.Requests++
	k.LastUsed = now.Unix()
	dirty = true
	return true
}

func modelOK(k *Key, m string) bool {
	if k.Admin || len(k.Models) == 0 {
		return true
	}
	for _, x := range k.Models {
		if x == m || x == "*" {
			return true
		}
	}
	return false
}

func errJSON(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"message": msg, "type": http.StatusText(code), "code": code}})
}

// ---- upstream helpers ----

func upReq(method, path string, body []byte) (*http.Response, error) {
	req, _ := http.NewRequest(method, upstream+path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+upKey)
	req.Header.Set("Content-Type", "application/json")
	return (&http.Client{Timeout: 20 * time.Minute}).Do(req)
}

type upModel struct {
	ID     string `json:"id"`
	Status struct {
		Value string `json:"value"`
	} `json:"status"`
}

func upModels() ([]upModel, error) {
	r, err := upReq("GET", "/models", nil)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	var d struct{ Data []upModel }
	err = json.NewDecoder(r.Body).Decode(&d)
	return d.Data, err
}

func modelBytes(id string) int64 {
	if st, err := os.Stat(filepath.Join(modelsDir, id+".gguf")); err == nil {
		return st.Size()
	}
	var t int64
	fs, _ := filepath.Glob(filepath.Join(modelsDir, id, "*"))
	for _, f := range fs {
		if st, err := os.Stat(f); err == nil {
			t += st.Size()
		}
	}
	return t
}

// memory guard: unload other models if the target would not fit beside them
func ensureFits(target string) {
	ms, err := upModels()
	if err != nil {
		return
	}
	need := modelBytes(target) + 2e9
	var loaded []string
	var sum int64
	for _, m := range ms {
		if m.Status.Value == "loaded" || m.Status.Value == "loading" {
			if m.ID == target {
				return
			}
			loaded = append(loaded, m.ID)
			sum += modelBytes(m.ID) + 2e9
		}
	}
	if sum+need <= memBudget {
		return
	}
	for _, id := range loaded {
		b, _ := json.Marshal(map[string]string{"model": id})
		if r, err := upReq("POST", "/models/unload", b); err == nil {
			r.Body.Close()
		}
	}
	time.Sleep(500 * time.Millisecond)
}

func installedIDs() map[string]bool {
	out := map[string]bool{}
	if ms, err := upModels(); err == nil {
		for _, m := range ms {
			out[m.ID] = true
		}
	}
	return out
}

// ---- chat primitives ----

type msg struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}

func textOf(c any) string {
	switch v := c.(type) {
	case string:
		return v
	case []any:
		var s []string
		for _, p := range v {
			if m, ok := p.(map[string]any); ok && m["type"] == "text" {
				s = append(s, fmt.Sprint(m["text"]))
			}
		}
		return strings.Join(s, "\n")
	}
	return ""
}

var thinkRe = regexp.MustCompile(`(?s)<think>.*?</think>`)

func chatOnce(model string, msgs []msg, extra map[string]any) (string, int64, error) {
	body := map[string]any{}
	for k, v := range extra {
		body[k] = v
	}
	body["model"] = model
	body["messages"] = msgs
	body["stream"] = false
	model = applyAlias(body)
	if isReasoner(model) {
		if v, _ := body["max_tokens"].(float64); v < 2048 {
			body["max_tokens"] = 2048 // thinking models need room to think before answering
		}
	}
	var r *http.Response
	var err error
	if pr, remote := findExt(model); pr != nil {
		body["model"] = remote
		b, _ := json.Marshal(body)
		r, err = extReq(pr, "POST", "/chat/completions", b)
	} else {
		b, _ := json.Marshal(body)
		ensureFits(model)
		r, err = upReq("POST", "/v1/chat/completions", b)
	}
	if err != nil {
		return "", 0, err
	}
	defer r.Body.Close()
	var d struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			Total int64 `json:"total_tokens"`
		} `json:"usage"`
	}
	raw, _ := io.ReadAll(r.Body)
	if r.StatusCode != 200 {
		return "", 0, fmt.Errorf("%s: upstream %d: %.200s", model, r.StatusCode, raw)
	}
	if err := json.Unmarshal(raw, &d); err != nil || len(d.Choices) == 0 {
		return "", 0, fmt.Errorf("%s: bad upstream reply", model)
	}
	out := thinkRe.ReplaceAllString(d.Choices[0].Message.Content, "")
	if i := strings.Index(out, "</think>"); i >= 0 {
		out = out[i+8:]
	}
	out = strings.TrimSpace(out)
	if out == "" {
		return "", d.Usage.Total, fmt.Errorf("%s returned an empty answer", model)
	}
	return out, d.Usage.Total, nil
}

func isReasoner(id string) bool {
	l := strings.ToLower(id)
	return strings.Contains(l, "r1") || strings.Contains(l, "qwq") || strings.Contains(l, "reason")
}

var (
	codeRe   = regexp.MustCompile("(?i)```|\\b(code|function|bug|error|compile|python|javascript|typescript|swift|golang|rust|java|c\\+\\+|sql|regex|script|api|class|method|stack ?trace|debug|refactor|bash|html|css)\\b")
	reasonRe = regexp.MustCompile(`(?i)\b(prove|proof|reason through|logic|puzzle|math|calculate|solve|equation|step[- ]by[- ]step|riddle|probability|derive|how many)\b|\d+\s*[-+*/^=]\s*\d+`)
)

func pick(m *Merge, q string) string {
	coder, reasoner, general := "", "", ""
	for _, id := range m.Models {
		l := strings.ToLower(id)
		switch {
		case strings.Contains(l, "coder") || strings.Contains(l, "code"):
			coder = id
		case isReasoner(id):
			reasoner = id
		default:
			if general == "" {
				general = id
			}
		}
	}
	if general == "" {
		general = m.Models[len(m.Models)-1]
	}
	if coder != "" && codeRe.MatchString(q) {
		return coder
	}
	if reasoner != "" && reasonRe.MatchString(q) {
		return reasoner
	}
	return general
}

type step struct {
	Model string  `json:"model"`
	Role  string  `json:"role"`
	Secs  float64 `json:"seconds"`
}

func runMerge(m *Merge, msgs []msg, extra map[string]any) (string, []step, int64, error) {
	var steps []step
	var tok int64
	call := func(model, role string, ms []msg) (string, error) {
		t := time.Now()
		out, n, err := chatOnce(model, ms, extra)
		tok += n
		steps = append(steps, step{model, role, time.Since(t).Seconds()})
		return out, err
	}
	last := ""
	if len(msgs) > 0 {
		last = textOf(msgs[len(msgs)-1].Content)
	}
	switch m.Mode {
	case "router":
		model := pick(m, last)
		out, err := call(model, "routed", msgs)
		if err != nil && model != m.Models[len(m.Models)-1] {
			out, err = call(m.Models[len(m.Models)-1], "fallback", msgs)
		}
		return out, steps, tok, err
	case "draft_refine":
		if len(m.Models) < 2 {
			return "", nil, 0, errors.New("draft_refine needs 2 models")
		}
		draft, err := call(m.Models[0], "draft", msgs)
		if err != nil {
			return "", steps, tok, err
		}
		ref := append(append([]msg{}, msgs...), msg{"assistant", draft},
			msg{"user", "Above is a draft reply to my last message. Rewrite it into the best possible final answer: fix mistakes, fill gaps, improve clarity. Reply with only the final answer, no commentary about the draft."})
		out, err := call(m.Models[1], "refine", ref)
		return out, steps, tok, err
	case "panel_judge":
		var answers []string
		for _, id := range m.Models {
			a, err := call(id, "panel", msgs)
			if err != nil {
				return "", steps, tok, err
			}
			answers = append(answers, a)
		}
		judge := m.Judge
		if judge == "" {
			judge = m.Models[0]
		}
		var sb strings.Builder
		sb.WriteString("Question:\n" + last + "\n\n")
		for i, a := range answers {
			fmt.Fprintf(&sb, "--- Answer %d ---\n%s\n\n", i+1, a)
		}
		sb.WriteString("You are the judge. Compare the answers above for correctness and helpfulness, then write the single best final answer (pick the best one or synthesize them). Reply with only the final answer.")
		ctx := append([]msg{}, msgs[:len(msgs)-1]...)
		ctx = append(ctx, msg{"user", sb.String()})
		out, err := call(judge, "judge", ctx)
		return out, steps, tok, err
	}
	return "", nil, 0, fmt.Errorf("unknown mode %q", m.Mode)
}

func findMerge(model string) *Merge {
	if !strings.HasPrefix(model, mergePref) {
		return nil
	}
	n := strings.TrimPrefix(model, mergePref)
	mu.Lock()
	defer mu.Unlock()
	for _, m := range merges {
		if m.Name == n {
			c := *m
			return &c
		}
	}
	return nil
}

// ---- handlers ----

func handleModels(w http.ResponseWriter, k *Key) {
	ms, err := upModels()
	if err != nil {
		errJSON(w, 502, "model server unavailable")
		return
	}
	var data []map[string]any
	for _, m := range ms {
		if modelOK(k, m.ID) {
			data = append(data, map[string]any{"id": m.ID, "object": "model", "owned_by": "redx", "created": 0})
		}
	}
	for _, e := range extModelsList() {
		if modelOK(k, e["id"].(string)) {
			data = append(data, e)
		}
	}
	mu.Lock()
	for _, mg := range merges {
		if modelOK(k, mergePref+mg.Name) {
			data = append(data, map[string]any{"id": mergePref + mg.Name, "object": "model", "owned_by": "redx-merge", "created": 0, "merge": mg})
		}
	}
	mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"object": "list", "data": data})
}

func handleV1(w http.ResponseWriter, r *http.Request, k *Key) {
	path := r.URL.Path
	if path == "/v1/models" && r.Method == "GET" {
		handleModels(w, k)
		return
	}
	if r.Method != "POST" || (path != "/v1/chat/completions" && path != "/v1/completions" && path != "/v1/embeddings") {
		errJSON(w, 404, "not found")
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		errJSON(w, 413, "request too large")
		return
	}
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	model, _ := body["model"].(string)
	if model == "" {
		model = defaultModel()
		body["model"] = model
	}
	if _, isAlias := loadAliases()[strings.TrimSuffix(model, ":latest")]; isAlias {
		if !modelOK(k, model) && !modelOK(k, loadAliases()[strings.TrimSuffix(model, ":latest")].From) {
			errJSON(w, 403, "this key may not use model "+model)
			return
		}
		model = applyAlias(body)
	} else if strings.HasSuffix(model, ":latest") {
		model = strings.TrimSuffix(model, ":latest")
		body["model"] = model
	}
	if !modelOK(k, model) && !k.Admin {
		if _, a := loadAliases()[body["model"].(string)]; !a {
			errJSON(w, 403, "this key may not use model "+model)
			return
		}
	}
	for _, f := range []string{"max_tokens", "max_completion_tokens", "n_predict"} {
		if v, ok := body[f].(float64); ok && v > maxTokens {
			body[f] = maxTokens
		}
	}
	if _, ok := body["max_tokens"]; !ok && path != "/v1/embeddings" {
		body["max_tokens"] = maxTokens
	}
	if mg := findMerge(model); mg != nil {
		if path != "/v1/chat/completions" {
			errJSON(w, 400, "merge models support chat completions only")
			return
		}
		serveMerge(w, r, k, mg, body)
		return
	}
	if strings.HasPrefix(model, mergePref) {
		errJSON(w, 404, "unknown merge "+model)
		return
	}
	if pr, remote := findExt(model); pr != nil {
		body["model"] = remote
		nb, _ := json.Marshal(body)
		resp, err := extReq(pr, "POST", extPath(path), nb)
		if err != nil {
			errJSON(w, 502, "provider unavailable: "+pr.Name)
			return
		}
		defer resp.Body.Close()
		if v := resp.Header.Get("Content-Type"); v != "" {
			w.Header().Set("Content-Type", v)
		}
		w.WriteHeader(resp.StatusCode)
		fl, _ := w.(http.Flusher)
		buf := make([]byte, 4096)
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				w.Write(buf[:n])
				if fl != nil {
					fl.Flush()
				}
			}
			if err != nil {
				break
			}
		}
		return
	}
	if !installedIDs()[model] {
		errJSON(w, 404, "model not installed: "+model)
		return
	}
	select {
	case gen <- struct{}{}:
	case <-r.Context().Done():
		return
	}
	defer func() { <-gen }()
	ensureFits(model)
	nb, _ := json.Marshal(body)
	resp, err := upReq("POST", path, nb)
	if err != nil {
		errJSON(w, 502, "model server unavailable")
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Cache-Control"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	stream, _ := body["stream"].(bool)
	if stream {
		fl, _ := w.(http.Flusher)
		br := bufio.NewReader(resp.Body)
		buf := make([]byte, 4096)
		for {
			n, err := br.Read(buf)
			if n > 0 {
				w.Write(buf[:n])
				if fl != nil {
					fl.Flush()
				}
			}
			if err != nil {
				break
			}
		}
		return
	}
	out, _ := io.ReadAll(resp.Body)
	var u struct {
		Usage struct {
			Total int64 `json:"total_tokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(out, &u) == nil {
		mu.Lock()
		k.Tokens += u.Usage.Total
		mu.Unlock()
	}
	w.Write(out)
}

func serveMerge(w http.ResponseWriter, r *http.Request, k *Key, mg *Merge, body map[string]any) {
	var msgs []msg
	b, _ := json.Marshal(body["messages"])
	if json.Unmarshal(b, &msgs) != nil || len(msgs) == 0 {
		errJSON(w, 400, "messages required")
		return
	}
	extra := map[string]any{}
	for _, f := range []string{"temperature", "top_p", "max_tokens", "seed"} {
		if v, ok := body[f]; ok {
			extra[f] = v
		}
	}
	select {
	case gen <- struct{}{}:
	case <-r.Context().Done():
		return
	}
	defer func() { <-gen }()
	t0 := time.Now()
	out, steps, tok, err := runMerge(mg, msgs, extra)
	if err != nil {
		errJSON(w, 502, "merge failed: "+err.Error())
		return
	}
	mu.Lock()
	k.Tokens += tok
	mu.Unlock()
	id := "chatcmpl-merge-" + randB62(12)
	meta := map[string]any{"merge": mg.Name, "mode": mg.Mode, "models_used": len(steps), "steps": steps, "seconds": time.Since(t0).Seconds()}
	if stream, _ := body["stream"].(bool); stream {
		w.Header().Set("Content-Type", "text/event-stream")
		ch := map[string]any{"id": id, "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": mergePref + mg.Name, "redx": meta,
			"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"role": "assistant", "content": out}, "finish_reason": "stop"}}}
		b, _ := json.Marshal(ch)
		fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", b)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"id": id, "object": "chat.completion", "created": time.Now().Unix(), "model": mergePref + mg.Name, "redx": meta,
		"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "content": out}, "finish_reason": "stop"}},
		"usage":   map[string]any{"total_tokens": tok}})
}

func defaultModel() string {
	b, _ := os.ReadFile("/etc/dolphin/default-model")
	if s := strings.TrimSpace(string(b)); s != "" {
		return s
	}
	return "dolphin3-llama3.1-8b-q8"
}

func publicHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.URL.Path == "/" || r.URL.Path == "/health" {
		w.Write([]byte("ok\n"))
		return
	}
	k := auth(r)
	if k == nil {
		errJSON(w, 401, "invalid or missing API key")
		return
	}
	if !allow(k) {
		w.Header().Set("Retry-After", "10")
		errJSON(w, 429, "rate limit exceeded")
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/") {
		handleOllama(w, r, k)
		return
	}
	handleV1(w, r, k)
}

// ---- admin (loopback port only, admin key) ----

func dm(args ...string) ([]byte, error) {
	return exec.Command("/usr/local/bin/dolphin-models", append(args, "--json")...).Output()
}

func adminHandler(w http.ResponseWriter, r *http.Request) {
	k := auth(r)
	if k == nil || !k.Admin {
		errJSON(w, 401, "admin key required")
		return
	}
	p := r.URL.Path
	if strings.HasPrefix(p, "/api/") {
		handleOllama(w, r, k)
		return
	}
	if strings.HasPrefix(p, "/v1/") {
		mu.Lock()
		k.Requests++
		k.LastUsed = time.Now().Unix()
		dirty = true
		mu.Unlock()
		handleV1(w, r, k)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	var in map[string]any
	if r.Method == "POST" {
		json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in)
	}
	str := func(f string) string { s, _ := in[f].(string); return s }
	if providerAdmin(w, r, p, in) {
		return
	}
	switch {
	case p == "/admin/keys" && r.Method == "GET":
		mu.Lock()
		var out []map[string]any
		for _, x := range keys {
			if x.Admin {
				continue
			}
			out = append(out, map[string]any{"id": x.ID, "name": x.Name, "prefix": x.Prefix, "models": x.Models, "rpm": x.RPM,
				"created": x.Created, "last_used": x.LastUsed, "revoked": x.Revoked, "requests": x.Requests, "tokens": x.Tokens})
		}
		mu.Unlock()
		sort.Slice(out, func(i, j int) bool { return out[i]["created"].(int64) > out[j]["created"].(int64) })
		json.NewEncoder(w).Encode(map[string]any{"keys": out})
	case p == "/admin/keys" && r.Method == "POST":
		name := strings.TrimSpace(str("name"))
		if name == "" || len(name) > 64 {
			errJSON(w, 400, "name required")
			return
		}
		var models []string
		if a, ok := in["models"].([]any); ok {
			for _, v := range a {
				models = append(models, fmt.Sprint(v))
			}
		}
		rpm := 60
		if v, ok := in["rpm"].(float64); ok && v >= 1 && v <= 10000 {
			rpm = int(v)
		}
		plain := "redx_ai_" + randB62(40)
		nk := &Key{ID: "key_" + randB62(10), Name: name, Prefix: plain[:14] + "…", Hash: hashKey(plain), Models: models, RPM: rpm, Created: time.Now().Unix()}
		mu.Lock()
		keys = append(keys, nk)
		saveKeys()
		mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"id": nk.ID, "key": plain, "note": "shown once; store it now"})
	case strings.HasPrefix(p, "/admin/keys/") && (r.Method == "DELETE" || r.Method == "POST"):
		id := strings.TrimPrefix(strings.TrimSuffix(p, "/revoke"), "/admin/keys/")
		mu.Lock()
		found := false
		for _, x := range keys {
			if x.ID == id && !x.Admin {
				x.Revoked = time.Now().Unix()
				found = true
			}
		}
		saveKeys()
		mu.Unlock()
		if !found {
			errJSON(w, 404, "no such key")
			return
		}
		w.Write([]byte(`{"ok":true}`))
	case p == "/admin/models" && r.Method == "GET":
		b, _ := dm("list")
		w.Write(b)
	case p == "/admin/catalog":
		b, _ := dm("available")
		w.Write(b)
	case p == "/admin/jobs":
		b, _ := dm("jobs")
		w.Write(b)
	case p == "/admin/models/pull" && r.Method == "POST":
		id := str("id")
		if !regexp.MustCompile(`^[a-z0-9._-]{1,64}$`).MatchString(id) {
			errJSON(w, 400, "bad id")
			return
		}
		cmd := exec.Command("/usr/local/bin/dolphin-models", "pull", id, "--json")
		var eb bytes.Buffer
		cmd.Stdout = &eb
		if err := cmd.Start(); err != nil {
			errJSON(w, 500, "could not start")
			return
		}
		go func() { cmd.Wait(); log.Printf("pull %s: %s", id, strings.TrimSpace(eb.String())) }()
		w.Write([]byte(`{"ok":true,"started":true}`))
	case strings.HasPrefix(p, "/admin/models/") && r.Method == "DELETE":
		id := strings.TrimPrefix(p, "/admin/models/")
		if !regexp.MustCompile(`^[a-z0-9._-]{1,64}$`).MatchString(id) {
			errJSON(w, 400, "bad id")
			return
		}
		b, err := dm("remove", id)
		if err != nil && len(b) == 0 {
			errJSON(w, 500, "remove failed")
			return
		}
		w.Write(b)
	case p == "/admin/ollama/library":
		b, _ := dm("ollama-library")
		w.Write(b)
	case p == "/admin/ollama/tags":
		b, _ := dm("ollama-tags", r.URL.Query().Get("name"))
		w.Write(b)
	case p == "/admin/ollama/pull" && r.Method == "POST":
		ref := str("ref")
		if !regexp.MustCompile(`^[a-z0-9._/-]{1,80}(:[a-zA-Z0-9._-]{1,60})?$`).MatchString(ref) {
			errJSON(w, 400, "bad model reference")
			return
		}
		cmd := exec.Command("/usr/local/bin/dolphin-models", "ollama-pull", ref, "--json")
		if err := cmd.Start(); err != nil {
			errJSON(w, 500, "could not start")
			return
		}
		go cmd.Wait()
		w.Write([]byte(`{"ok":true,"started":true}`))
	case p == "/admin/aliases" && r.Method == "GET":
		b, _ := dm("aliases")
		w.Write(b)
	case p == "/admin/aliases" && r.Method == "POST":
		name, mf := str("name"), str("modelfile")
		if !regexp.MustCompile(`^[a-z0-9._-]{1,48}$`).MatchString(name) || len(mf) > 64<<10 {
			errJSON(w, 400, "bad alias name or Modelfile")
			return
		}
		f, err := os.CreateTemp("/opt/dolphin/cache", "modelfile-")
		if err != nil {
			errJSON(w, 500, "tmp failed")
			return
		}
		f.WriteString(mf)
		f.Close()
		defer os.Remove(f.Name())
		b, _ := dm("create", name, "-f", f.Name())
		w.Write(b)
	case strings.HasPrefix(p, "/admin/aliases/") && r.Method == "DELETE":
		b, _ := dm("alias-rm", strings.TrimPrefix(p, "/admin/aliases/"))
		w.Write(b)
	case p == "/admin/default" && r.Method == "POST":
		b, _ := dm("default", str("id"))
		w.Write(b)
	case p == "/admin/merges" && r.Method == "GET":
		mu.Lock()
		json.NewEncoder(w).Encode(map[string]any{"merges": merges})
		mu.Unlock()
	case p == "/admin/merges" && r.Method == "POST":
		var m Merge
		b, _ := json.Marshal(in)
		json.Unmarshal(b, &m)
		if !regexp.MustCompile(`^[a-z0-9-]{1,32}$`).MatchString(m.Name) || len(m.Models) == 0 ||
			(m.Mode != "router" && m.Mode != "draft_refine" && m.Mode != "panel_judge") || len(m.Models) > 4 {
			errJSON(w, 400, "need name [a-z0-9-], mode router|draft_refine|panel_judge, 1-4 models")
			return
		}
		if m.Mode == "draft_refine" && len(m.Models) != 2 {
			errJSON(w, 400, "draft_refine needs exactly 2 models (drafter, refiner)")
			return
		}
		mu.Lock()
		repl := false
		for i, x := range merges {
			if x.Name == m.Name {
				merges[i] = &m
				repl = true
			}
		}
		if !repl {
			merges = append(merges, &m)
		}
		saveMerges()
		mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "model": mergePref + m.Name})
	case strings.HasPrefix(p, "/admin/merges/") && r.Method == "DELETE":
		n := strings.TrimPrefix(p, "/admin/merges/")
		mu.Lock()
		var keep []*Merge
		for _, x := range merges {
			if x.Name != n {
				keep = append(keep, x)
			}
		}
		merges = keep
		saveMerges()
		mu.Unlock()
		w.Write([]byte(`{"ok":true}`))
	default:
		errJSON(w, 404, "not found")
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "init-admin" {
		os.MkdirAll(dir, 0700)
		load()
		plain := "redx_ai_" + randB62(40)
		for _, x := range keys {
			if x.Admin {
				x.Revoked = time.Now().Unix()
			}
		}
		keys = append(keys, &Key{ID: "admin_" + randB62(8), Name: "Dolphino admin", Prefix: plain[:14] + "…", Hash: hashKey(plain), Admin: true, Created: time.Now().Unix()})
		saveKeys()
		os.WriteFile(os.Args[2], []byte(plain+"\n"), 0600)
		fmt.Println("admin key written to", os.Args[2])
		return
	}
	load()
	go func() {
		for range time.Tick(15 * time.Second) {
			mu.Lock()
			if dirty {
				saveKeys()
				dirty = false
			}
			mu.Unlock()
		}
	}()
	go func() {
		s := &http.Server{Addr: "127.0.0.1:8092", Handler: http.HandlerFunc(adminHandler), ReadHeaderTimeout: 10 * time.Second}
		log.Fatal(s.ListenAndServe())
	}()
	s := &http.Server{Addr: "127.0.0.1:8091", Handler: http.HandlerFunc(publicHandler), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second}
	log.Println("dolphin-gateway public :8091 admin :8092")
	log.Fatal(s.ListenAndServe())
}
