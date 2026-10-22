package main

// Protocol shims so tools that only speak other wire formats can use every model here:
//   POST /v1/messages   Anthropic Messages API (Claude Code via ANTHROPIC_BASE_URL)
//   POST /v1/responses  OpenAI Responses API (Codex CLI, wire_api = "responses")
// Both translate to /v1/chat/completions internally (so merges, Vortex, providers, keys,
// scopes and learning all apply) and support stream=true by replaying the final result as SSE.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"time"
)

func chatInternal(r *http.Request, k *Key, body map[string]any) (map[string]any, int, string) {
	body["stream"] = false
	b, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(r.Context(), "POST", "/v1/chat/completions", bytes.NewReader(b))
	req.Header = r.Header.Clone()
	rec := httptest.NewRecorder()
	handleV1(rec, req, k)
	var out map[string]any
	if json.Unmarshal(rec.Body.Bytes(), &out) != nil {
		return nil, 502, "bad upstream response"
	}
	if rec.Code != 200 {
		msg := fmt.Sprint(out["error"])
		if m, ok := out["error"].(map[string]any); ok {
			msg = fmt.Sprint(m["message"])
		}
		return nil, rec.Code, msg
	}
	return out, 200, ""
}

func firstChoice(out map[string]any) (string, []any, string) {
	ch, _ := out["choices"].([]any)
	if len(ch) == 0 {
		return "", nil, "stop"
	}
	c, _ := ch[0].(map[string]any)
	m, _ := c["message"].(map[string]any)
	txt := strings.TrimSpace(thinkRe.ReplaceAllString(textOf(m["content"]), ""))
	tc, _ := m["tool_calls"].([]any)
	fr, _ := c["finish_reason"].(string)
	if len(tc) == 0 {
		if calls, rest := textToolCalls(txt); len(calls) > 0 {
			return rest, calls, "tool_calls"
		}
	}
	return txt, tc, fr
}

// Some local models (e.g. Qwen2.5-Coder) print tool calls as tagged JSON instead of using the
// tool-call channel. Recover them: <tool_call>{...}</tool_call>, <tools>{...}</tools>, or ```json {...}```.
var toolTagRe = regexp.MustCompile("(?s)<(tool_call|tools|function_call)>\\s*(.*?)\\s*</(?:tool_call|tools|function_call)>")

func textToolCalls(txt string) ([]any, string) {
	var calls []any
	rest := txt
	for _, m := range toolTagRe.FindAllStringSubmatch(txt, -1) {
		body := strings.TrimSpace(m[2])
		var items []map[string]any
		var one map[string]any
		if json.Unmarshal([]byte(body), &one) == nil {
			items = []map[string]any{one}
		} else if json.Unmarshal([]byte(body), &items) != nil {
			continue
		}
		for _, it := range items {
			name, _ := it["name"].(string)
			if name == "" {
				continue
			}
			args := it["arguments"]
			if args == nil {
				args = it["parameters"]
			}
			as, ok := args.(string)
			if !ok {
				b, _ := json.Marshal(args)
				as = string(b)
			}
			calls = append(calls, map[string]any{"id": "call_" + randB62(16), "type": "function", "function": map[string]any{"name": name, "arguments": as}})
		}
		rest = strings.Replace(rest, m[0], "", 1)
	}
	return calls, strings.TrimSpace(rest)
}

func usageOf(out map[string]any) (int, int) {
	u, _ := out["usage"].(map[string]any)
	p, _ := u["prompt_tokens"].(float64)
	c, _ := u["completion_tokens"].(float64)
	return int(p), int(c)
}

func readBody(w http.ResponseWriter, r *http.Request) map[string]any {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	var in map[string]any
	if err != nil || json.Unmarshal(raw, &in) != nil {
		return nil
	}
	return in
}

func sse(w http.ResponseWriter, event string, v any) {
	b, _ := json.Marshal(v)
	if event != "" {
		fmt.Fprintf(w, "event: %s\n", event)
	}
	fmt.Fprintf(w, "data: %s\n\n", b)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}

// ---------------- Anthropic Messages ----------------
func anthErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"type": "error", "error": map[string]any{"type": "api_error", "message": msg}})
}

func anthText(c any) string {
	switch v := c.(type) {
	case string:
		return v
	case []any:
		var sb strings.Builder
		for _, x := range v {
			if m, ok := x.(map[string]any); ok && m["type"] == "text" {
				sb.WriteString(fmt.Sprint(m["text"]))
			}
		}
		return sb.String()
	}
	return ""
}

func handleMessages(w http.ResponseWriter, r *http.Request, k *Key) {
	if strings.HasSuffix(r.URL.Path, "/count_tokens") {
		raw, _ := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"input_tokens": len(raw) / 4}) // estimate
		return
	}
	in := readBody(w, r)
	if in == nil {
		anthErr(w, 400, "invalid JSON")
		return
	}
	var msgs []any
	if s := anthText(in["system"]); s != "" {
		msgs = append(msgs, map[string]any{"role": "system", "content": s})
	}
	arr, _ := in["messages"].([]any)
	for _, x := range arr {
		m, _ := x.(map[string]any)
		role, _ := m["role"].(string)
		if s, ok := m["content"].(string); ok {
			msgs = append(msgs, map[string]any{"role": role, "content": s})
			continue
		}
		blocks, _ := m["content"].([]any)
		var text strings.Builder
		var calls []any
		for _, b := range blocks {
			bm, _ := b.(map[string]any)
			switch bm["type"] {
			case "text":
				text.WriteString(fmt.Sprint(bm["text"]))
			case "tool_use":
				args, _ := json.Marshal(bm["input"])
				calls = append(calls, map[string]any{"id": bm["id"], "type": "function", "function": map[string]any{"name": bm["name"], "arguments": string(args)}})
			case "tool_result":
				c := anthText(bm["content"])
				if s, ok := bm["content"].(string); ok {
					c = s
				}
				msgs = append(msgs, map[string]any{"role": "tool", "tool_call_id": bm["tool_use_id"], "content": c})
			}
		}
		if text.Len() > 0 || len(calls) > 0 {
			om := map[string]any{"role": role, "content": text.String()}
			if len(calls) > 0 {
				om["tool_calls"] = calls
			}
			msgs = append(msgs, om)
		}
	}
	body := map[string]any{"model": in["model"], "messages": msgs}
	if v, ok := in["max_tokens"]; ok {
		body["max_tokens"] = v
	}
	if v, ok := in["temperature"]; ok {
		body["temperature"] = v
	}
	if tl, ok := in["tools"].([]any); ok && len(tl) > 0 {
		var tools []any
		for _, t := range tl {
			tm, _ := t.(map[string]any)
			if tm["input_schema"] == nil {
				continue // server tools (web search etc.) are not available here
			}
			tools = append(tools, map[string]any{"type": "function", "function": map[string]any{"name": tm["name"], "description": tm["description"], "parameters": tm["input_schema"]}})
		}
		if len(tools) > 0 {
			body["tools"] = tools
		}
	}
	out, code, msg := chatInternal(r, k, body)
	if out == nil {
		anthErr(w, code, msg)
		return
	}
	txt, calls, fr := firstChoice(out)
	var content []any
	if txt != "" {
		content = append(content, map[string]any{"type": "text", "text": txt})
	}
	for _, c := range calls {
		cm, _ := c.(map[string]any)
		f, _ := cm["function"].(map[string]any)
		var input any = map[string]any{}
		json.Unmarshal([]byte(fmt.Sprint(f["arguments"])), &input)
		id, _ := cm["id"].(string)
		if id == "" {
			id = "toolu_" + randB62(20)
		}
		content = append(content, map[string]any{"type": "tool_use", "id": id, "name": f["name"], "input": input})
	}
	if len(content) == 0 {
		content = []any{map[string]any{"type": "text", "text": ""}}
	}
	stop := "end_turn"
	if len(calls) > 0 {
		stop = "tool_use"
	} else if fr == "length" {
		stop = "max_tokens"
	}
	pt, ct := usageOf(out)
	model, _ := in["model"].(string)
	id := "msg_" + randB62(22)
	usage := map[string]any{"input_tokens": pt, "output_tokens": ct}
	if st, _ := in["stream"].(bool); !st {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"id": id, "type": "message", "role": "assistant", "model": model, "content": content, "stop_reason": stop, "stop_sequence": nil, "usage": usage})
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	sse(w, "message_start", map[string]any{"type": "message_start", "message": map[string]any{"id": id, "type": "message", "role": "assistant", "model": model, "content": []any{}, "stop_reason": nil, "usage": map[string]any{"input_tokens": pt, "output_tokens": 0}}})
	for i, c := range content {
		cm := c.(map[string]any)
		if cm["type"] == "text" {
			sse(w, "content_block_start", map[string]any{"type": "content_block_start", "index": i, "content_block": map[string]any{"type": "text", "text": ""}})
			sse(w, "content_block_delta", map[string]any{"type": "content_block_delta", "index": i, "delta": map[string]any{"type": "text_delta", "text": cm["text"]}})
		} else {
			sse(w, "content_block_start", map[string]any{"type": "content_block_start", "index": i, "content_block": map[string]any{"type": "tool_use", "id": cm["id"], "name": cm["name"], "input": map[string]any{}}})
			js, _ := json.Marshal(cm["input"])
			sse(w, "content_block_delta", map[string]any{"type": "content_block_delta", "index": i, "delta": map[string]any{"type": "input_json_delta", "partial_json": string(js)}})
		}
		sse(w, "content_block_stop", map[string]any{"type": "content_block_stop", "index": i})
	}
	sse(w, "message_delta", map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": stop, "stop_sequence": nil}, "usage": map[string]any{"output_tokens": ct}})
	sse(w, "message_stop", map[string]any{"type": "message_stop"})
}

// ---------------- OpenAI Responses ----------------
func handleResponses(w http.ResponseWriter, r *http.Request, k *Key) {
	in := readBody(w, r)
	if in == nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	var msgs []any
	if s, _ := in["instructions"].(string); s != "" {
		msgs = append(msgs, map[string]any{"role": "system", "content": s})
	}
	var pendingCalls []any
	flush := func() {
		if len(pendingCalls) > 0 {
			msgs = append(msgs, map[string]any{"role": "assistant", "content": "", "tool_calls": pendingCalls})
			pendingCalls = nil
		}
	}
	switch v := in["input"].(type) {
	case string:
		msgs = append(msgs, map[string]any{"role": "user", "content": v})
	case []any:
		for _, x := range v {
			m, _ := x.(map[string]any)
			t, _ := m["type"].(string)
			if t == "" && m["role"] != nil {
				t = "message"
			}
			switch t {
			case "message":
				flush()
				role, _ := m["role"].(string)
				if role == "developer" {
					role = "system"
				}
				var sb strings.Builder
				if s, ok := m["content"].(string); ok {
					sb.WriteString(s)
				} else if parts, ok := m["content"].([]any); ok {
					for _, p := range parts {
						pm, _ := p.(map[string]any)
						if s, ok := pm["text"].(string); ok {
							sb.WriteString(s)
						}
					}
				}
				msgs = append(msgs, map[string]any{"role": role, "content": sb.String()})
			case "function_call":
				pendingCalls = append(pendingCalls, map[string]any{"id": m["call_id"], "type": "function", "function": map[string]any{"name": m["name"], "arguments": m["arguments"]}})
			case "function_call_output":
				flush()
				out := m["output"]
				if _, ok := out.(string); !ok {
					b, _ := json.Marshal(out)
					out = string(b)
				}
				msgs = append(msgs, map[string]any{"role": "tool", "tool_call_id": m["call_id"], "content": out})
			}
		}
	}
	flush()
	body := map[string]any{"model": in["model"], "messages": msgs}
	if v, ok := in["max_output_tokens"]; ok {
		body["max_tokens"] = v
	}
	if v, ok := in["temperature"]; ok {
		body["temperature"] = v
	}
	if tl, ok := in["tools"].([]any); ok {
		var tools []any
		for _, t := range tl {
			tm, _ := t.(map[string]any)
			if tm["type"] != "function" {
				continue // built-in hosted tools are not available on local models
			}
			tools = append(tools, map[string]any{"type": "function", "function": map[string]any{"name": tm["name"], "description": tm["description"], "parameters": tm["parameters"]}})
		}
		if len(tools) > 0 {
			body["tools"] = tools
		}
	}
	out, code, msg := chatInternal(r, k, body)
	if out == nil {
		errJSON(w, code, msg)
		return
	}
	txt, calls, _ := firstChoice(out)
	var items []any
	if txt != "" {
		items = append(items, map[string]any{"type": "message", "id": "msg_" + randB62(16), "status": "completed", "role": "assistant",
			"content": []any{map[string]any{"type": "output_text", "text": txt, "annotations": []any{}}}})
	}
	for _, c := range calls {
		cm, _ := c.(map[string]any)
		f, _ := cm["function"].(map[string]any)
		cid, _ := cm["id"].(string)
		if cid == "" {
			cid = "call_" + randB62(16)
		}
		items = append(items, map[string]any{"type": "function_call", "id": "fc_" + randB62(16), "status": "completed", "call_id": cid, "name": f["name"], "arguments": fmt.Sprint(f["arguments"])})
	}
	pt, ct := usageOf(out)
	resp := map[string]any{"id": "resp_" + randB62(20), "object": "response", "created_at": time.Now().Unix(), "status": "completed", "model": in["model"],
		"output": items, "usage": map[string]any{"input_tokens": pt, "output_tokens": ct, "total_tokens": pt + ct}}
	if st, _ := in["stream"].(bool); !st {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	seq := 0
	ev := func(t string, v map[string]any) { v["type"] = t; v["sequence_number"] = seq; seq++; sse(w, t, v) }
	start := map[string]any{}
	for k2, v := range resp {
		start[k2] = v
	}
	start["status"] = "in_progress"
	start["output"] = []any{}
	ev("response.created", map[string]any{"response": start})
	for i, it := range items {
		im := it.(map[string]any)
		ev("response.output_item.added", map[string]any{"output_index": i, "item": im})
		if im["type"] == "message" {
			ev("response.output_text.delta", map[string]any{"output_index": i, "item_id": im["id"], "content_index": 0, "delta": txt})
			ev("response.output_text.done", map[string]any{"output_index": i, "item_id": im["id"], "content_index": 0, "text": txt})
		} else {
			ev("response.function_call_arguments.done", map[string]any{"output_index": i, "item_id": im["id"], "arguments": im["arguments"]})
		}
		ev("response.output_item.done", map[string]any{"output_index": i, "item": im})
	}
	ev("response.completed", map[string]any{"response": resp})
}
