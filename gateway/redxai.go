package main

// Red-XAI: a persona model on top of the best local base, with a sealed knowledge store (RAG),
// a sealed feedback dataset for LoRA training, scoped redx_xai_ keys and versioned adapters.

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
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
	rxDir   = "/opt/dolphin/redxai"
	rxCfg   = "/etc/dolphin/redxai/config.json"
	rxModel = "red-xai"
	rxShard = 400
	rxChunk = 900
)

type RXConfig struct {
	Base        string  `json:"base"`
	Coder       string  `json:"coder"`
	Reasoner    string  `json:"reasoner"`
	EmbedModel  string  `json:"embed_model"`
	Persona     string  `json:"persona"`
	RagK        int     `json:"rag_k"`
	RagMinScore float64 `json:"rag_min_score"`
	Active      string  `json:"active_version"` // "" = base only, or "v1", "v2"…
}

var rxDefault = RXConfig{
	Base: "dolphin2.7-mixtral-8x7b-iq4xs", Coder: "qwen2.5-coder-14b", Reasoner: "r1-distill-qwen-14b", EmbedModel: "nomic-embed-v1.5",
	Persona: "You are Red-XAI, the assistant built by Red-XAI. You are direct, warm and precise. Use the KNOWLEDGE section when it is relevant and say when you are unsure. Never invent facts about Red-XAI.",
	RagK:    4, RagMinScore: 0.45,
}

type rxChunkT struct {
	ID  string    `json:"id"`
	Src string    `json:"src"`
	Txt string    `json:"text"`
	Vec []float32 `json:"vec"`
	TS  int64     `json:"ts"`
}

var (
	rxMu     sync.Mutex
	rxKB     []rxChunkT
	rxSeen   = map[string]bool{}
	rxKBKey  []byte
	rxShards int
)

func rxConfig() RXConfig {
	c := rxDefault
	if b, err := os.ReadFile(rxCfg); err == nil {
		json.Unmarshal(b, &c)
	}
	return c
}

func rxInit() {
	os.MkdirAll(filepath.Join(rxDir, "kb"), 0700)
	os.MkdirAll(filepath.Join(rxDir, "datasets"), 0700)
	os.MkdirAll(filepath.Join(rxDir, "adapters"), 0755)
	os.MkdirAll(filepath.Dir(rxCfg), 0700)
	k, err := os.ReadFile(filepath.Join(dir, "kb.key"))
	if errors.Is(err, os.ErrNotExist) {
		k, err = cbRandom(32)
		must(err)
		must(os.WriteFile(filepath.Join(dir, "kb.key"), k, 0600))
	} else {
		must(err)
	}
	rxKBKey = k
	files, _ := filepath.Glob(filepath.Join(rxDir, "kb", "kb-*.rxkb"))
	sort.Strings(files)
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		pt, err := rxOpen(b, "kb:"+filepath.Base(f))
		if err != nil {
			continue
		}
		var cs []rxChunkT
		if json.Unmarshal(pt, &cs) == nil {
			rxKB = append(rxKB, cs...)
		}
	}
	rxShards = len(files)
	for _, c := range rxKB {
		rxSeen[c.ID] = true
	}
}

func rxSeal(pt []byte, aad string) ([]byte, error) {
	n, err := cbRandom(12)
	if err != nil {
		return nil, err
	}
	ct, err := cbSeal(rxKBKey, n, []byte("redx-xai-v1:"+aad), pt)
	return append(n, ct...), err
}
func rxOpen(b []byte, aad string) ([]byte, error) {
	if len(b) < 28 {
		return nil, errors.New("short")
	}
	return cbOpen(rxKBKey, b[:12], []byte("redx-xai-v1:"+aad), b[12:])
}

func rxID(text string) string {
	h := cbHMAC(rxKBKey, []byte("dedupe\x00"+strings.ToLower(strings.Join(strings.Fields(text), " "))))
	return hex.EncodeToString(h[:12])
}

// persist rewrites the newest shard (and opens new ones every rxShard chunks)
func rxPersist() error {
	total := len(rxKB)
	shards := (total + rxShard - 1) / rxShard
	start := 0
	if rxShards > 0 {
		start = rxShards - 1
	}
	for s := start; s < shards; s++ {
		end := (s + 1) * rxShard
		if end > total {
			end = total
		}
		b, _ := json.Marshal(rxKB[s*rxShard : end])
		name := fmt.Sprintf("kb-%06d.rxkb", s+1)
		sealed, err := rxSeal(b, "kb:"+name)
		if err != nil {
			return err
		}
		tmp := filepath.Join(rxDir, "kb", name+".tmp")
		if err := os.WriteFile(tmp, sealed, 0600); err != nil {
			return err
		}
		os.Rename(tmp, filepath.Join(rxDir, "kb", name))
	}
	rxShards = shards
	return nil
}

var (
	piiEmail = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`)
	piiPhone = regexp.MustCompile(`\+?\d[\d\s().-]{8,}\d`)
	piiCard  = regexp.MustCompile(`\b(?:\d[ -]?){13,19}\b`)
	piiIP    = regexp.MustCompile(`\b\d{1,3}(?:\.\d{1,3}){3}\b`)
	piiKey   = regexp.MustCompile(`\b(?:sk|pk|rk|redx_ai|redx_xai|ghp|github_pat|xox[abp]|AKIA)[-_A-Za-z0-9]{12,}\b`)
)

func scrubPII(s string) string {
	s = piiKey.ReplaceAllString(s, "[secret]")
	s = piiEmail.ReplaceAllString(s, "[email]")
	s = piiCard.ReplaceAllString(s, "[number]")
	s = piiIP.ReplaceAllString(s, "[ip]")
	s = piiPhone.ReplaceAllString(s, "[phone]")
	return s
}

func embed(texts []string) ([][]float32, error) {
	c := rxConfig()
	b, _ := json.Marshal(map[string]any{"model": c.EmbedModel, "input": texts})
	ensureFits(c.EmbedModel)
	r, err := upReq("POST", "/v1/embeddings", b)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	var d struct {
		Data []struct {
			Embedding []float32 `json:"embedding"`
		} `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&d); err != nil || len(d.Data) != len(texts) {
		return nil, fmt.Errorf("embedding failed (%d)", r.StatusCode)
	}
	out := make([][]float32, len(texts))
	for i, e := range d.Data {
		out[i] = norm(e.Embedding)
	}
	return out, nil
}
func norm(v []float32) []float32 {
	var s float64
	for _, x := range v {
		s += float64(x * x)
	}
	s = math.Sqrt(s)
	if s == 0 {
		return v
	}
	for i := range v {
		v[i] = float32(float64(v[i]) / s)
	}
	return v
}

func chunkText(t string) []string {
	t = strings.TrimSpace(t)
	var out []string
	paras := regexp.MustCompile(`\n\s*\n`).Split(t, -1)
	cur := ""
	for _, p := range paras {
		p = strings.Join(strings.Fields(p), " ")
		for len(p) > rxChunk {
			cut := strings.LastIndex(p[:rxChunk], ". ")
			if cut < rxChunk/2 {
				cut = rxChunk
			} else {
				cut += 1
			}
			out = append(out, strings.TrimSpace(p[:cut]))
			p = strings.TrimSpace(p[cut:])
		}
		if len(cur)+len(p) > rxChunk && cur != "" {
			out = append(out, cur)
			cur = ""
		}
		if cur != "" {
			cur += "\n"
		}
		cur += p
	}
	if strings.TrimSpace(cur) != "" {
		out = append(out, cur)
	}
	var keep []string
	for _, c := range out {
		if len(c) >= 40 {
			keep = append(keep, c)
		}
	}
	return keep
}

type ingestDoc struct {
	Text   string `json:"text"`
	Source string `json:"source"`
}

func rxIngest(docs []ingestDoc, scrub bool) (added, dupes int, err error) {
	var texts, srcs []string
	rxMu.Lock()
	seenBatch := map[string]bool{}
	for _, d := range docs {
		t := d.Text
		if scrub {
			t = scrubPII(t)
		}
		for _, c := range chunkText(t) {
			id := rxID(c)
			if rxSeen[id] || seenBatch[id] {
				dupes++
				continue
			}
			seenBatch[id] = true
			texts = append(texts, c)
			srcs = append(srcs, d.Source)
		}
	}
	rxMu.Unlock()
	for i := 0; i < len(texts); i += 16 {
		j := i + 16
		if j > len(texts) {
			j = len(texts)
		}
		in := make([]string, 0, j-i)
		for _, t := range texts[i:j] {
			in = append(in, "search_document: "+t)
		}
		vs, e := embed(in)
		if e != nil {
			return added, dupes, e
		}
		rxMu.Lock()
		for k, v := range vs {
			c := rxChunkT{ID: rxID(texts[i+k]), Src: srcs[i+k], Txt: texts[i+k], Vec: v, TS: time.Now().Unix()}
			rxKB = append(rxKB, c)
			rxSeen[c.ID] = true
			added++
		}
		err = rxPersist()
		rxMu.Unlock()
		if err != nil {
			return
		}
	}
	return
}

type hit struct {
	Score float64 `json:"score"`
	Src   string  `json:"source"`
	Text  string  `json:"text"`
}

func rxSearch(q string, k int) []hit {
	rxMu.Lock()
	n := len(rxKB)
	rxMu.Unlock()
	if n == 0 || strings.TrimSpace(q) == "" {
		return nil
	}
	vs, err := embed([]string{"search_query: " + q})
	if err != nil {
		return nil
	}
	v := vs[0]
	rxMu.Lock()
	defer rxMu.Unlock()
	hs := make([]hit, 0, len(rxKB))
	for _, c := range rxKB {
		if len(c.Vec) != len(v) {
			continue
		}
		var s float64
		for i := range v {
			s += float64(v[i] * c.Vec[i])
		}
		hs = append(hs, hit{s, c.Src, c.Txt})
	}
	sort.Slice(hs, func(i, j int) bool { return hs[i].Score > hs[j].Score })
	if len(hs) > k {
		hs = hs[:k]
	}
	return hs
}

func rxVersions() []string {
	ds, _ := filepath.Glob(filepath.Join(rxDir, "adapters", "v*"))
	var out []string
	for _, d := range ds {
		if fs, _ := filepath.Glob(filepath.Join(d, "*.gguf")); len(fs) > 0 {
			out = append(out, filepath.Base(d))
		}
	}
	sort.Strings(out)
	return out
}

func isRedXAI(m string) bool { return m == rxModel || strings.HasPrefix(m, rxModel+"-v") }

// rxPrepare rewrites a chat body for Red-XAI: picks the capability model, adds persona + knowledge.
func rxPrepare(body map[string]any) (string, map[string]any) {
	c := rxConfig()
	req, _ := body["model"].(string)
	ver := strings.TrimPrefix(req, rxModel+"-")
	if req == rxModel {
		ver = c.Active
	}
	target := c.Base
	if ver != "" && ver != rxModel {
		target = rxModel + "-" + ver // router preset with the LoRA adapter applied
	}
	msgs, _ := body["messages"].([]any)
	last := ""
	for i := len(msgs) - 1; i >= 0; i-- {
		if m, _ := msgs[i].(map[string]any); m != nil && m["role"] == "user" {
			last = textOf(m["content"])
			break
		}
	}
	capab := "chat"
	if c.Coder != "" && codeRe.MatchString(last) {
		target, capab = c.Coder, "coding"
	} else if c.Reasoner != "" && reasonRe.MatchString(last) && len(last) > 60 {
		target, capab = c.Reasoner, "reasoning"
		if v, _ := body["max_tokens"].(float64); v < 2048 {
			body["max_tokens"] = 2048
		}
	}
	sys := c.Persona
	hits := rxSearch(last, c.RagK)
	used := 0
	var kb strings.Builder
	for _, h := range hits {
		if h.Score < c.RagMinScore {
			continue
		}
		used++
		fmt.Fprintf(&kb, "\n[%d] (%s) %s", used, h.Src, h.Text)
	}
	if used > 0 {
		sys += "\n\nKNOWLEDGE (retrieved; cite as [n] when used):" + kb.String()
	}
	var nm []any
	nm = append(nm, map[string]any{"role": "system", "content": sys})
	for _, m := range msgs {
		if mm, _ := m.(map[string]any); mm != nil && mm["role"] == "system" {
			nm = append(nm, map[string]any{"role": "system", "content": mm["content"]})
			continue
		}
		nm = append(nm, m)
	}
	body["messages"] = nm
	body["model"] = target
	return target, map[string]any{"capability": capab, "routed_to": target, "knowledge_used": used, "version": ver}
}

func hasScope(k *Key, s string) bool {
	if k.Admin || !strings.HasPrefix(k.Prefix, "redx_xai_") {
		return true
	}
	for _, x := range k.Scopes {
		if x == s || x == "*" {
			return true
		}
	}
	return false
}

func appendDataset(rec map[string]any) error {
	rec["ts"] = time.Now().Unix()
	b, _ := json.Marshal(rec)
	name := "feedback-" + time.Now().Format("200601") + ".rxds"
	sealed, err := rxSeal(b, "ds:"+name)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(rxDir, "datasets", name), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(hex.EncodeToString(sealed) + "\n")
	return err
}

func readDataset() []map[string]any {
	var out []map[string]any
	fs, _ := filepath.Glob(filepath.Join(rxDir, "datasets", "*.rxds"))
	for _, f := range fs {
		fh, err := os.Open(f)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for sc.Scan() {
			b, err := hex.DecodeString(strings.TrimSpace(sc.Text()))
			if err != nil {
				continue
			}
			pt, err := rxOpen(b, "ds:"+filepath.Base(f))
			if err != nil {
				continue
			}
			var m map[string]any
			if json.Unmarshal(pt, &m) == nil {
				out = append(out, m)
			}
		}
		fh.Close()
	}
	return out
}

func scrubAny(v any) any {
	switch t := v.(type) {
	case string:
		return scrubPII(t)
	case []any:
		for i := range t {
			t[i] = scrubAny(t[i])
		}
		return t
	case map[string]any:
		for k, x := range t {
			t[k] = scrubAny(x)
		}
		return t
	}
	return v
}

// /v1/redxai/* (public, keyed)
func handleRedXAI(w http.ResponseWriter, r *http.Request, k *Key) {
	w.Header().Set("Content-Type", "application/json")
	p := strings.TrimPrefix(r.URL.Path, "/v1/redxai/")
	var in map[string]any
	if r.Method == "POST" {
		if json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&in) != nil {
			errJSON(w, 400, "invalid JSON")
			return
		}
	}
	switch {
	case p == "info" && r.Method == "GET":
		c := rxConfig()
		rxMu.Lock()
		n := len(rxKB)
		rxMu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"model": rxModel, "base": c.Base, "active_version": c.Active, "versions": rxVersions(), "knowledge_chunks": n,
			"capabilities": map[string]any{"chat": true, "coding": c.Coder, "reasoning": c.Reasoner, "embeddings": c.EmbedModel, "memory": true, "image": imageReady(), "audio": audioReady()}})
	case p == "search" && r.Method == "GET":
		if !hasScope(k, "chat") {
			errJSON(w, 403, "key lacks scope chat")
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"results": rxSearch(r.URL.Query().Get("q"), 8)})
	case p == "ingest" && r.Method == "POST":
		if !hasScope(k, "train:submit") {
			errJSON(w, 403, "key lacks scope train:submit")
			return
		}
		var docs []ingestDoc
		if a, ok := in["documents"].([]any); ok {
			for _, d := range a {
				m, _ := d.(map[string]any)
				t, _ := m["text"].(string)
				s, _ := m["source"].(string)
				docs = append(docs, ingestDoc{t, s})
			}
		} else if t, ok := in["text"].(string); ok {
			s, _ := in["source"].(string)
			docs = []ingestDoc{{t, s}}
		}
		if len(docs) == 0 || len(docs) > 200 {
			errJSON(w, 400, "send text or 1-200 documents")
			return
		}
		for i := range docs {
			if docs[i].Source == "" {
				docs[i].Source = "app:" + k.Name
			}
		}
		select {
		case gen <- struct{}{}:
		case <-r.Context().Done():
			return
		}
		added, dupes, err := rxIngest(docs, !k.Admin)
		<-gen
		if err != nil {
			errJSON(w, 502, err.Error())
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "chunks_added": added, "duplicates_skipped": dupes})
	case p == "feedback" && r.Method == "POST":
		if !hasScope(k, "train:submit") {
			errJSON(w, 403, "key lacks scope train:submit")
			return
		}
		if c, _ := in["consent"].(bool); !c {
			errJSON(w, 400, "consent:true is required to store training data")
			return
		}
		rating, _ := in["rating"].(float64)
		rec := map[string]any{"source": "key:" + k.Name, "messages": scrubAny(in["messages"]), "response": scrubAny(in["response"]),
			"rating": rating, "correction": scrubAny(in["correction"]), "model": in["model"]}
		if err := appendDataset(rec); err != nil {
			errJSON(w, 500, "store failed")
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true})
	default:
		errJSON(w, 404, "not found")
	}
}

// admin: /admin/redxai/*
func redxaiAdmin(w http.ResponseWriter, r *http.Request, p string, in map[string]any) bool {
	if !strings.HasPrefix(p, "/admin/redxai/") {
		return false
	}
	sub := strings.TrimPrefix(p, "/admin/redxai/")
	switch {
	case sub == "config" && r.Method == "GET":
		json.NewEncoder(w).Encode(rxConfig())
	case sub == "config" && r.Method == "POST":
		c := rxConfig()
		b, _ := json.Marshal(in)
		json.Unmarshal(b, &c)
		if c.RagK < 0 || c.RagK > 12 {
			c.RagK = 4
		}
		writeJSONPath(rxCfg, c)
		json.NewEncoder(w).Encode(c)
	case sub == "stats":
		ds := readDataset()
		up, down, corr := 0, 0, 0
		for _, d := range ds {
			if v, _ := d["rating"].(float64); v > 0 {
				up++
			} else if v < 0 {
				down++
			}
			if s, _ := d["correction"].(string); s != "" {
				corr++
			}
		}
		rxMu.Lock()
		n := len(rxKB)
		srcs := map[string]int{}
		for _, c := range rxKB {
			s := c.Src
			if i := strings.Index(s, "/"); strings.HasPrefix(s, "http") {
				parts := strings.SplitN(s, "/", 4)
				if len(parts) > 2 {
					s = parts[2]
				}
				_ = i
			}
			srcs[s]++
		}
		rxMu.Unlock()
		ev, _ := os.ReadFile(filepath.Join(rxDir, "eval.json"))
		var evj any
		json.Unmarshal(ev, &evj)
		json.NewEncoder(w).Encode(map[string]any{"knowledge_chunks": n, "knowledge_sources": srcs, "feedback": len(ds), "thumbs_up": up, "thumbs_down": down,
			"corrections": corr, "versions": rxVersions(), "config": rxConfig(), "eval": evj, "image": imageReady(), "audio": audioReady()})
	case sub == "export" && r.Method == "POST":
		// plaintext JSONL for the trainer (root-only file); good = thumbs up, or a correction replaces the reply
		ds := readDataset()
		os.MkdirAll(filepath.Join(rxDir, "export"), 0700)
		name := filepath.Join(rxDir, "export", "train-"+time.Now().Format("20060102-150405")+".jsonl")
		f, err := os.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
		if err != nil {
			errJSON(w, 500, "export failed")
			return true
		}
		n := 0
		for _, d := range ds {
			msgs, _ := d["messages"].([]any)
			reply, _ := d["response"].(string)
			if c, _ := d["correction"].(string); c != "" {
				reply = c
			} else if v, _ := d["rating"].(float64); v <= 0 {
				continue
			}
			if len(msgs) == 0 || reply == "" {
				continue
			}
			all := append([]any{map[string]any{"role": "system", "content": rxConfig().Persona}}, msgs...)
			all = append(all, map[string]any{"role": "assistant", "content": reply})
			b, _ := json.Marshal(map[string]any{"messages": all})
			f.Write(append(b, '\n'))
			n++
		}
		f.Close()
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "file": name, "examples": n})
	case sub == "eval" && r.Method == "POST":
		cmd := exec.Command("/usr/local/bin/redxai-eval")
		if err := cmd.Start(); err != nil {
			errJSON(w, 500, "eval not installed")
			return true
		}
		go cmd.Wait()
		w.Write([]byte(`{"ok":true,"started":true}`))
	case sub == "kb" && r.Method == "DELETE":
		src := r.URL.Query().Get("source")
		if src == "" {
			errJSON(w, 400, "source required")
			return true
		}
		rxMu.Lock()
		var keep []rxChunkT
		for _, c := range rxKB {
			if c.Src != src && !(strings.HasSuffix(src, "*") && strings.HasPrefix(c.Src, strings.TrimSuffix(src, "*"))) {
				keep = append(keep, c)
			} else {
				delete(rxSeen, c.ID)
			}
		}
		removed := len(rxKB) - len(keep)
		rxKB = keep
		files, _ := filepath.Glob(filepath.Join(rxDir, "kb", "kb-*.rxkb"))
		for _, f := range files {
			os.Remove(f)
		}
		rxShards = 0
		err := rxPersist()
		rxMu.Unlock()
		if err != nil {
			errJSON(w, 500, "persist failed")
			return true
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "removed": removed})
	case sub == "crawl" && r.Method == "POST":
		cmd := exec.Command("/usr/local/bin/redxai-crawl")
		if err := cmd.Start(); err != nil {
			errJSON(w, 500, "crawler not installed")
			return true
		}
		go cmd.Wait()
		w.Write([]byte(`{"ok":true,"started":true}`))
	case sub == "crawl-config" && r.Method == "GET":
		b, err := os.ReadFile("/etc/dolphin/redxai/crawl.json")
		if err != nil {
			b = []byte(`{"seeds":[],"max_pages":200,"delay_seconds":2,"same_domain":true}`)
		}
		w.Write(b)
	case sub == "crawl-config" && r.Method == "POST":
		writeJSONPath("/etc/dolphin/redxai/crawl.json", in)
		w.Write([]byte(`{"ok":true}`))
	default:
		errJSON(w, 404, "not found")
	}
	return true
}

func writeJSONPath(path string, v any) {
	b, _ := json.MarshalIndent(v, "", " ")
	os.WriteFile(path+".tmp", b, 0600)
	os.Rename(path+".tmp", path)
}

func imageReady() bool {
	_, e1 := os.Stat("/opt/dolphin/bin/sd")
	m, _ := filepath.Glob("/opt/dolphin/media-models/image/*")
	return e1 == nil && len(m) > 0
}
func audioReady() bool {
	_, e := os.Stat("/opt/dolphin/audio/venv/bin/python")
	return e == nil
}
