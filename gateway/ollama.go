package main

// Ollama-compatible API (/api/tags, /api/chat, /api/generate, /api/embed, /api/embeddings, /api/show, /api/version)
// and Ollama-style aliases (Modelfile FROM/SYSTEM/PARAMETER) applied to every API.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"time"
)

type Alias struct {
	Name   string         `json:"name"`
	From   string         `json:"from"`
	System string         `json:"system,omitempty"`
	Params map[string]any `json:"params,omitempty"`
}

func loadAliases() map[string]Alias {
	out := map[string]Alias{}
	b, err := os.ReadFile("/etc/dolphin/aliases.json")
	if err != nil {
		return out
	}
	var a []Alias
	json.Unmarshal(b, &a)
	for _, x := range a {
		out[x.Name] = x
	}
	return out
}

var ollamaParamMap = map[string]string{"temperature": "temperature", "top_p": "top_p", "top_k": "top_k", "num_predict": "max_tokens",
	"repeat_penalty": "repeat_penalty", "seed": "seed", "stop": "stop", "min_p": "min_p", "presence_penalty": "presence_penalty", "frequency_penalty": "frequency_penalty"}

// applyAlias rewrites body in place if model is an alias. Returns resolved model.
func applyAlias(body map[string]any) string {
	model, _ := body["model"].(string)
	for i := 0; i < 4; i++ {
		a, ok := loadAliases()[strings.TrimSuffix(model, ":latest")]
		if !ok {
			break
		}
		model = a.From
		body["model"] = model
		for k, v := range a.Params {
			if ok, _ := ollamaParamMap[k]; ok != "" {
				if _, set := body[ok]; !set {
					body[ok] = v
				}
			}
		}
		if a.System != "" {
			if msgs, ok := body["messages"].([]any); ok {
				has := false
				for _, m := range msgs {
					if mm, _ := m.(map[string]any); mm != nil && mm["role"] == "system" {
						has = true
					}
				}
				if !has {
					body["messages"] = append([]any{map[string]any{"role": "system", "content": a.System}}, msgs...)
				}
			}
		}
	}
	return model
}

func ollamaTime() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func handleOllama(w http.ResponseWriter, r *http.Request, k *Key) {
	p := r.URL.Path
	w.Header().Set("Content-Type", "application/json")
	if p == "/api/version" {
		w.Write([]byte(`{"version":"0.6.0-redx"}`))
		return
	}
	if p == "/api/tags" || p == "/api/ps" {
		rec := httptest.NewRecorder()
		handleModels(rec, k)
		var d struct{ Data []map[string]any }
		json.Unmarshal(rec.Body.Bytes(), &d)
		var ms []map[string]any
		for _, m := range d.Data {
			id, _ := m["id"].(string)
			ms = append(ms, map[string]any{"name": id, "model": id, "modified_at": ollamaTime(), "size": modelBytes(id), "digest": "",
				"details": map[string]any{"format": "gguf", "family": "", "parameter_size": "", "quantization_level": ""}})
		}
		for n, a := range loadAliases() {
			if modelOK(k, n) || modelOK(k, a.From) {
				ms = append(ms, map[string]any{"name": n, "model": n, "modified_at": ollamaTime(), "size": modelBytes(a.From), "digest": "", "details": map[string]any{"format": "gguf", "parent_model": a.From}})
			}
		}
		json.NewEncoder(w).Encode(map[string]any{"models": ms})
		return
	}
	if r.Method != "POST" {
		errJSON(w, 404, "not found")
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		errJSON(w, 413, "request too large")
		return
	}
	var in map[string]any
	if json.Unmarshal(raw, &in) != nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	model, _ := in["model"].(string)
	if p == "/api/show" {
		if model == "" {
			model, _ = in["name"].(string)
		}
		a := loadAliases()[model]
		json.NewEncoder(w).Encode(map[string]any{"modelfile": "FROM " + model, "parameters": "", "template": "", "system": a.System,
			"details": map[string]any{"format": "gguf"}, "model_info": map[string]any{}, "capabilities": []string{"completion"}})
		return
	}
	out := map[string]any{"model": model}
	if opts, ok := in["options"].(map[string]any); ok {
		for kk, v := range opts {
			if m := ollamaParamMap[kk]; m != "" {
				out[m] = v
			}
		}
	}
	stream := true
	if s, ok := in["stream"].(bool); ok {
		stream = s
	}
	var path string
	switch p {
	case "/api/chat":
		path = "/v1/chat/completions"
		out["messages"] = in["messages"]
	case "/api/generate":
		path = "/v1/chat/completions"
		var msgs []any
		if s, _ := in["system"].(string); s != "" {
			msgs = append(msgs, map[string]any{"role": "system", "content": s})
		}
		msgs = append(msgs, map[string]any{"role": "user", "content": in["prompt"]})
		out["messages"] = msgs
		if raw, _ := in["raw"].(bool); raw {
			path = "/v1/completions"
			delete(out, "messages")
			out["prompt"] = in["prompt"]
		}
	case "/api/embed", "/api/embeddings":
		path = "/v1/embeddings"
		if v, ok := in["input"]; ok {
			out["input"] = v
		} else {
			out["input"] = in["prompt"]
		}
		stream = false
	default:
		errJSON(w, 404, "not found")
		return
	}
	if path != "/v1/embeddings" {
		out["stream"] = stream
	}
	nb, _ := json.Marshal(out)
	sub, _ := http.NewRequestWithContext(r.Context(), "POST", path, bytes.NewReader(nb))
	if stream {
		tw := &ndjsonWriter{w: w, model: model, gen: p == "/api/generate", hdr: http.Header{}}
		w.Header().Set("Content-Type", "application/x-ndjson")
		handleV1(tw, sub, k)
		tw.finish()
		return
	}
	rec := httptest.NewRecorder()
	handleV1(rec, sub, k)
	if rec.Code != 200 {
		w.WriteHeader(rec.Code)
		w.Write(rec.Body.Bytes())
		return
	}
	var d map[string]any
	json.Unmarshal(rec.Body.Bytes(), &d)
	if path == "/v1/embeddings" {
		var embs [][]any
		for _, e := range d["data"].([]any) {
			embs = append(embs, e.(map[string]any)["embedding"].([]any))
		}
		if p == "/api/embeddings" && len(embs) > 0 {
			json.NewEncoder(w).Encode(map[string]any{"embedding": embs[0]})
		} else {
			json.NewEncoder(w).Encode(map[string]any{"model": model, "embeddings": embs})
		}
		return
	}
	text := ""
	if ch, _ := d["choices"].([]any); len(ch) > 0 {
		c := ch[0].(map[string]any)
		if m, ok := c["message"].(map[string]any); ok {
			text, _ = m["content"].(string)
		} else {
			text, _ = c["text"].(string)
		}
	}
	res := map[string]any{"model": model, "created_at": ollamaTime(), "done": true, "done_reason": "stop"}
	if p == "/api/generate" {
		res["response"] = text
	} else {
		res["message"] = map[string]any{"role": "assistant", "content": text}
	}
	json.NewEncoder(w).Encode(res)
}

// ndjsonWriter converts an OpenAI SSE stream (or a single JSON error) into Ollama NDJSON chunks.
type ndjsonWriter struct {
	w     http.ResponseWriter
	model string
	gen   bool
	buf   []byte
	hdr   http.Header
	code  int
	done  bool
}

func (n *ndjsonWriter) Header() http.Header { return n.hdr }
func (n *ndjsonWriter) WriteHeader(c int) {
	n.code = c
	if c != 200 {
		n.w.WriteHeader(c)
	}
}
func (n *ndjsonWriter) Flush() {
	if f, ok := n.w.(http.Flusher); ok {
		f.Flush()
	}
}
func (n *ndjsonWriter) emit(text string, done bool) {
	o := map[string]any{"model": n.model, "created_at": ollamaTime(), "done": done}
	if n.gen {
		o["response"] = text
	} else {
		o["message"] = map[string]any{"role": "assistant", "content": text}
	}
	if done {
		o["done_reason"] = "stop"
	}
	b, _ := json.Marshal(o)
	n.w.Write(append(b, '\n'))
	n.Flush()
}
func (n *ndjsonWriter) Write(b []byte) (int, error) {
	if n.code != 0 && n.code != 200 {
		return n.w.Write(b)
	}
	n.buf = append(n.buf, b...)
	for {
		i := bytes.IndexByte(n.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimSpace(string(n.buf[:i]))
		n.buf = n.buf[i+1:]
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		pl := strings.TrimSpace(line[5:])
		if pl == "[DONE]" {
			n.done = true
			n.emit("", true)
			continue
		}
		var d struct {
			Choices []struct {
				Delta struct{ Content string } `json:"delta"`
				Text  string                   `json:"text"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(pl), &d) == nil && len(d.Choices) > 0 {
			t := d.Choices[0].Delta.Content + d.Choices[0].Text
			if t != "" {
				n.emit(t, false)
			}
		}
	}
	return len(b), nil
}
func (n *ndjsonWriter) finish() {
	if !n.done && (n.code == 0 || n.code == 200) {
		n.emit("", true)
	}
}
