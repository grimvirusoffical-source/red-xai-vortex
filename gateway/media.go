package main

// Red-XAI media capabilities, run on CPU:
//   POST /v1/images/generations  (stable-diffusion.cpp + a free turbo model)  scope "image"
//   POST /v1/audio/generations   (MusicGen-small via transformers)            scope "audio"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var mediaLock = make(chan struct{}, 1)

func handleMedia(w http.ResponseWriter, r *http.Request, k *Key) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != "POST" {
		errJSON(w, 404, "not found")
		return
	}
	var in map[string]any
	if json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in) != nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	prompt, _ := in["prompt"].(string)
	if strings.TrimSpace(prompt) == "" || len(prompt) > 2000 {
		errJSON(w, 400, "prompt required (max 2000 chars)")
		return
	}
	isImg := r.URL.Path == "/v1/images/generations"
	isAud := r.URL.Path == "/v1/audio/generations"
	if !isImg && !isAud {
		errJSON(w, 404, "not found")
		return
	}
	scope := map[bool]string{true: "image", false: "audio"}[isImg]
	if !hasScope(k, scope) {
		errJSON(w, 403, "key lacks scope "+scope)
		return
	}
	if (isImg && !imageReady()) || (isAud && !audioReady()) {
		errJSON(w, 503, scope+" generation is not installed on this server")
		return
	}
	select {
	case mediaLock <- struct{}{}:
	case <-r.Context().Done():
		return
	}
	defer func() { <-mediaLock }()
	// media runs alone: free the LLM's RAM first
	if ms, err := upModels(); err == nil {
		for _, m := range ms {
			if m.Status.Value == "loaded" {
				b, _ := json.Marshal(map[string]string{"model": m.ID})
				if resp, err := upReq("POST", "/models/unload", b); err == nil {
					resp.Body.Close()
				}
			}
		}
	}
	tmp, _ := os.MkdirTemp("/opt/dolphin/cache", "media-")
	defer os.RemoveAll(tmp)
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()
	t0 := time.Now()
	if isImg {
		w0, h0 := 512, 512
		if s, _ := in["size"].(string); s != "" {
			if p := strings.SplitN(s, "x", 2); len(p) == 2 {
				a, e1 := strconv.Atoi(p[0])
				b, e2 := strconv.Atoi(p[1])
				if e1 == nil && e2 == nil && a >= 256 && a <= 1024 && b >= 256 && b <= 1024 {
					w0, h0 = a/64*64, b/64*64
				}
			}
		}
		models, _ := filepath.Glob("/opt/dolphin/media-models/image/*")
		steps := "4"
		if v, ok := in["steps"].(float64); ok && v >= 1 && v <= 30 {
			steps = strconv.Itoa(int(v))
		}
		out := filepath.Join(tmp, "out.png")
		cmd := exec.CommandContext(ctx, "/opt/dolphin/bin/sd", "-m", models[0], "-p", prompt, "-o", out,
			"-W", strconv.Itoa(w0), "-H", strconv.Itoa(h0), "--steps", steps, "--cfg-scale", "1.0", "--sampling-method", "euler_a", "-t", "16")
		cmd.Env = append(os.Environ(), "LD_LIBRARY_PATH=/opt/dolphin/bin")
		if b, err := cmd.CombinedOutput(); err != nil {
			errJSON(w, 500, "image generation failed: "+lastLine(string(b)))
			return
		}
		img, err := os.ReadFile(out)
		if err != nil {
			errJSON(w, 500, "no image produced")
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"created": time.Now().Unix(), "data": []any{map[string]any{"b64_json": base64.StdEncoding.EncodeToString(img)}},
			"redx": map[string]any{"seconds": time.Since(t0).Seconds(), "size": strconv.Itoa(w0) + "x" + strconv.Itoa(h0), "steps": steps}})
		return
	}
	dur := 8.0
	if v, ok := in["duration"].(float64); ok && v >= 1 && v <= 30 {
		dur = v
	}
	out := filepath.Join(tmp, "out.wav")
	cmd := exec.CommandContext(ctx, "/opt/dolphin/audio/venv/bin/python", "/opt/dolphin/audio/gen.py", prompt, strconv.FormatFloat(dur, 'f', 1, 64), out)
	if b, err := cmd.CombinedOutput(); err != nil {
		errJSON(w, 500, "audio generation failed: "+lastLine(string(b)))
		return
	}
	wav, err := os.ReadFile(out)
	if err != nil {
		errJSON(w, 500, "no audio produced")
		return
	}
	json.NewEncoder(w).Encode(map[string]any{"created": time.Now().Unix(), "format": "wav", "b64_audio": base64.StdEncoding.EncodeToString(wav),
		"redx": map[string]any{"seconds": time.Since(t0).Seconds(), "duration": dur}})
}

func lastLine(s string) string {
	ls := strings.Split(strings.TrimSpace(s), "\n")
	l := ls[len(ls)-1]
	if len(l) > 300 {
		l = l[:300]
	}
	return l
}
