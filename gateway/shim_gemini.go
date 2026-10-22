package main

// Gemini-native shim for Gemini CLI (GOOGLE_GEMINI_BASE_URL + GEMINI_API_KEY):
//   POST /v1beta/models/{model}:generateContent
//   POST /v1beta/models/{model}:streamGenerateContent?alt=sse
//   POST /v1beta/models/{model}:countTokens
// Translated to chat completions so every model, merge and Vortex works.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

func handleGemini(w http.ResponseWriter, r *http.Request, k *Key) {
	p := r.URL.Path
	i := strings.Index(p, "/models/")
	if i < 0 || r.Method != "POST" {
		errJSON(w, 404, "not found")
		return
	}
	rest := p[i+len("/models/"):]
	model, action, _ := strings.Cut(rest, ":")
	if action == "countTokens" {
		raw, _ := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"totalTokens": len(raw) / 4})
		return
	}
	in := readBody(w, r)
	if in == nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	var msgs []any
	if si, ok := in["systemInstruction"].(map[string]any); ok {
		msgs = append(msgs, map[string]any{"role": "system", "content": gemParts(si)})
	}
	contents, _ := in["contents"].([]any)
	callN := 0
	var lastIDs []string
	for _, c := range contents {
		cm, _ := c.(map[string]any)
		role := "user"
		if cm["role"] == "model" {
			role = "assistant"
		}
		parts, _ := cm["parts"].([]any)
		var text strings.Builder
		var calls []any
		var ids []string
		for _, pt := range parts {
			pm, _ := pt.(map[string]any)
			if t, ok := pm["text"].(string); ok && pm["thought"] != true {
				text.WriteString(t)
			}
			if fc, ok := pm["functionCall"].(map[string]any); ok {
				args, _ := json.Marshal(fc["args"])
				id := fmt.Sprintf("call_%d", callN)
				callN++
				ids = append(ids, id)
				calls = append(calls, map[string]any{"id": id, "type": "function", "function": map[string]any{"name": fc["name"], "arguments": string(args)}})
			}
			if fr, ok := pm["functionResponse"].(map[string]any); ok {
				out, _ := json.Marshal(fr["response"])
				id := ""
				if len(lastIDs) > 0 {
					id, lastIDs = lastIDs[0], lastIDs[1:]
				}
				msgs = append(msgs, map[string]any{"role": "tool", "tool_call_id": id, "content": string(out)})
			}
		}
		if text.Len() > 0 || len(calls) > 0 {
			om := map[string]any{"role": role, "content": text.String()}
			if len(calls) > 0 {
				om["tool_calls"] = calls
				lastIDs = ids
			}
			msgs = append(msgs, om)
		}
	}
	body := map[string]any{"model": model, "messages": msgs}
	if gc, ok := in["generationConfig"].(map[string]any); ok {
		if v, ok := gc["maxOutputTokens"]; ok {
			body["max_tokens"] = v
		}
		if v, ok := gc["temperature"]; ok {
			body["temperature"] = v
		}
	}
	if tl, ok := in["tools"].([]any); ok {
		var tools []any
		for _, t := range tl {
			tm, _ := t.(map[string]any)
			fds, _ := tm["functionDeclarations"].([]any)
			for _, fd := range fds {
				f, _ := fd.(map[string]any)
				params := f["parameters"]
				if params == nil {
					params = f["parametersJsonSchema"]
				}
				if params == nil {
					params = map[string]any{"type": "object", "properties": map[string]any{}}
				}
				tools = append(tools, map[string]any{"type": "function", "function": map[string]any{"name": f["name"], "description": f["description"], "parameters": lowerTypes(params)}})
			}
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
	txt, calls, fr := firstChoice(out)
	var parts []any
	if txt != "" {
		parts = append(parts, map[string]any{"text": txt})
	}
	for _, c := range calls {
		cm, _ := c.(map[string]any)
		f, _ := cm["function"].(map[string]any)
		var args any = map[string]any{}
		json.Unmarshal([]byte(fmt.Sprint(f["arguments"])), &args)
		parts = append(parts, map[string]any{"functionCall": map[string]any{"name": f["name"], "args": args}})
	}
	if len(parts) == 0 {
		parts = []any{map[string]any{"text": ""}}
	}
	finish := "STOP"
	if fr == "length" {
		finish = "MAX_TOKENS"
	}
	pt, ct := usageOf(out)
	resp := map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"role": "model", "parts": parts}, "finishReason": finish, "index": 0}},
		"usageMetadata": map[string]any{"promptTokenCount": pt, "candidatesTokenCount": ct, "totalTokenCount": pt + ct}, "modelVersion": model}
	if action == "streamGenerateContent" {
		w.Header().Set("Content-Type", "text/event-stream")
		sse(w, "", resp)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func gemParts(c map[string]any) string {
	var sb strings.Builder
	parts, _ := c["parts"].([]any)
	for _, p := range parts {
		if pm, ok := p.(map[string]any); ok {
			if t, ok := pm["text"].(string); ok {
				sb.WriteString(t)
			}
		}
	}
	return sb.String()
}

// Gemini schemas use "STRING"/"OBJECT"; JSON Schema wants lowercase.
func lowerTypes(v any) any {
	switch x := v.(type) {
	case map[string]any:
		o := map[string]any{}
		for k, val := range x {
			if k == "type" {
				if s, ok := val.(string); ok {
					o[k] = strings.ToLower(s)
					continue
				}
			}
			o[k] = lowerTypes(val)
		}
		return o
	case []any:
		for i := range x {
			x[i] = lowerTypes(x[i])
		}
	}
	return v
}
