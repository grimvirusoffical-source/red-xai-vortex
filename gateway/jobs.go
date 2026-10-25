package main

// Red-XAI media job queue (CPU, one job at a time):
//   POST /v1/jobs            {"type":"image|music|speech|sfx|video","prompt":"…", …} → {"id","status","position"}
//   GET  /v1/jobs/{id}       → status queued|running|done|error, progress 0-100, position, seconds, result
//   GET  /v1/jobs            → this key's recent jobs (no result payloads)
//   POST /v1/audio/speech    OpenAI-style TTS ("input") → WAV bytes (synchronous; Piper is fast)
// Every finished job is written to the media learning log (sealed with rsx, PII scrubbed):
//   GET  /admin/learning/media?n=50 (admin)

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type mediaJob struct {
	ID       string         `json:"id"`
	Type     string         `json:"type"`
	Status   string         `json:"status"`
	Progress int            `json:"progress"`
	Position int            `json:"position,omitempty"`
	Created  int64          `json:"created"`
	Started  int64          `json:"started,omitempty"`
	Seconds  float64        `json:"seconds,omitempty"`
	Error    string         `json:"error,omitempty"`
	Result   map[string]any `json:"result,omitempty"`
	in       map[string]any
	keyID    string
	keyName  string
	finished time.Time
}

var (
	jobsMu    sync.Mutex
	jobs      = map[string]*mediaJob{}
	jobQueue  []*mediaJob
	jobWake   = make(chan struct{}, 1)
	jobOnce   sync.Once
	progRe    = regexp.MustCompile(`(\d+)/(\d+)`)
	jobScopes = map[string]string{"image": "image", "music": "audio", "speech": "audio", "sfx": "audio", "video": "video"}
)

func ttsReady() bool  { _, e := os.Stat("/opt/dolphin/tts/piper/piper"); return e == nil }
func gen2Ready() bool { _, e := os.Stat("/opt/dolphin/audio/gen2.py"); return e == nil && audioReady() }
func hfModel(n string) bool {
	m, _ := filepath.Glob("/opt/dolphin/audio/hf/hub/models--" + n + "/snapshots/*")
	return len(m) > 0
}
func jobReady(t string) bool {
	switch t {
	case "image":
		return imageReady()
	case "music":
		return audioReady()
	case "speech":
		return ttsReady()
	case "sfx":
		return gen2Ready() && hfModel("cvssp--audioldm-s-full-v2")
	case "video":
		return gen2Ready() && hfModel("ali-vilab--text-to-video-ms-1.7b")
	}
	return false
}

func handleJobs(w http.ResponseWriter, r *http.Request, k *Key) {
	w.Header().Set("Content-Type", "application/json")
	jobOnce.Do(func() { go jobWorker() })
	p := strings.TrimSuffix(r.URL.Path, "/")
	if p == "/v1/jobs" && r.Method == "GET" {
		jobsMu.Lock()
		var out []mediaJob
		for _, j := range jobs {
			if j.keyID == k.ID {
				c := *j
				c.Result = nil
				out = append(out, c)
			}
		}
		jobsMu.Unlock()
		sort.Slice(out, func(a, b int) bool { return out[a].Created > out[b].Created })
		json.NewEncoder(w).Encode(map[string]any{"object": "list", "data": out})
		return
	}
	if strings.HasPrefix(p, "/v1/jobs/") && r.Method == "GET" {
		id := strings.TrimPrefix(p, "/v1/jobs/")
		jobsMu.Lock()
		j := jobs[id]
		var c mediaJob
		if j != nil && j.keyID == k.ID {
			c = *j
			c.Position = queuePos(j)
		}
		jobsMu.Unlock()
		if c.ID == "" {
			errJSON(w, 404, "job not found")
			return
		}
		json.NewEncoder(w).Encode(c)
		return
	}
	if p != "/v1/jobs" || r.Method != "POST" {
		errJSON(w, 404, "not found")
		return
	}
	var in map[string]any
	if json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in) != nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	t, _ := in["type"].(string)
	scope, ok := jobScopes[t]
	if !ok {
		errJSON(w, 400, "type must be image, music, speech, sfx or video")
		return
	}
	prompt, _ := in["prompt"].(string)
	if prompt == "" {
		prompt, _ = in["input"].(string)
		in["prompt"] = prompt
	}
	if strings.TrimSpace(prompt) == "" || len(prompt) > 2000 {
		errJSON(w, 400, "prompt required (max 2000 chars)")
		return
	}
	if !hasScope(k, scope) {
		errJSON(w, 403, "key lacks scope "+scope)
		return
	}
	if !jobReady(t) {
		errJSON(w, 503, t+" generation is not installed on this server")
		return
	}
	j := &mediaJob{ID: "job_" + randB62(12), Type: t, Status: "queued", Created: time.Now().Unix(), in: in, keyID: k.ID, keyName: k.Name}
	jobsMu.Lock()
	n := 0
	for _, q := range jobQueue {
		if q.keyID == k.ID {
			n++
		}
	}
	if n >= 5 {
		jobsMu.Unlock()
		errJSON(w, 429, "too many queued jobs for this key (max 5)")
		return
	}
	jobs[j.ID] = j
	jobQueue = append(jobQueue, j)
	pos := queuePos(j)
	jobsMu.Unlock()
	select {
	case jobWake <- struct{}{}:
	default:
	}
	w.WriteHeader(202)
	json.NewEncoder(w).Encode(map[string]any{"id": j.ID, "type": t, "status": "queued", "position": pos})
}

// queuePos: 1-based place in line (0 = running or finished). Caller holds jobsMu.
func queuePos(j *mediaJob) int {
	for i, q := range jobQueue {
		if q == j {
			return i + 1
		}
	}
	return 0
}

func jobWorker() {
	for {
		jobsMu.Lock()
		// drop finished jobs after 1 hour
		for id, j := range jobs {
			if !j.finished.IsZero() && time.Since(j.finished) > time.Hour {
				delete(jobs, id)
			}
		}
		if len(jobQueue) == 0 {
			jobsMu.Unlock()
			select {
			case <-jobWake:
			case <-time.After(time.Minute):
			}
			continue
		}
		j := jobQueue[0]
		jobQueue = jobQueue[1:]
		j.Status, j.Started = "running", time.Now().Unix()
		jobsMu.Unlock()

		mediaLock <- struct{}{}
		freeLLM()
		t0 := time.Now()
		res, err := runMedia(context.Background(), j.Type, j.in, func(p int) {
			jobsMu.Lock()
			if p > j.Progress && p <= 99 {
				j.Progress = p
			}
			jobsMu.Unlock()
		})
		<-mediaLock
		jobsMu.Lock()
		j.Seconds = time.Since(t0).Seconds()
		j.finished = time.Now()
		if err != nil {
			j.Status, j.Error = "error", err.Error()
		} else {
			j.Status, j.Progress, j.Result = "done", 100, res
		}
		jobsMu.Unlock()
		logMedia(j, err)
	}
}

func freeLLM() {
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
}

func numIn(in map[string]any, f string, def, lo, hi float64) float64 {
	if v, ok := in[f].(float64); ok && v >= lo && v <= hi {
		return v
	}
	return def
}

// runMedia runs one generation and reports progress (0-99). Result: b64 + mime + meta.
func runMedia(ctx context.Context, t string, in map[string]any, prog func(int)) (map[string]any, error) {
	prompt, _ := in["prompt"].(string)
	tmp, _ := os.MkdirTemp("/opt/dolphin/cache", "job-")
	defer os.RemoveAll(tmp)
	ctx, cancel := context.WithTimeout(ctx, 20*time.Minute)
	defer cancel()
	var cmd *exec.Cmd
	var out, mime string
	meta := map[string]any{}
	estimate := 30.0 // seconds, for time-based progress when the tool prints none
	switch t {
	case "image":
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
		steps := strconv.Itoa(int(numIn(in, "steps", 4, 1, 30)))
		models, _ := filepath.Glob("/opt/dolphin/media-models/image/*")
		out, mime = filepath.Join(tmp, "out.png"), "image/png"
		cmd = exec.CommandContext(ctx, "/opt/dolphin/bin/sd", "-m", models[0], "-p", prompt, "-o", out,
			"-W", strconv.Itoa(w0), "-H", strconv.Itoa(h0), "--steps", steps, "--cfg-scale", "1.0", "--sampling-method", "euler_a", "-t", "16")
		cmd.Env = append(os.Environ(), "LD_LIBRARY_PATH=/opt/dolphin/bin")
		meta["size"], meta["steps"] = fmt.Sprintf("%dx%d", w0, h0), steps
		estimate = 15
	case "music":
		dur := numIn(in, "duration", 8, 1, 30)
		out, mime = filepath.Join(tmp, "out.wav"), "audio/wav"
		cmd = exec.CommandContext(ctx, "/opt/dolphin/audio/venv/bin/python", "/opt/dolphin/audio/gen.py", prompt, strconv.FormatFloat(dur, 'f', 1, 64), out)
		meta["duration"], estimate = dur, 8+dur*2.5
	case "speech":
		out, mime = filepath.Join(tmp, "out.wav"), "audio/wav"
		cmd = exec.CommandContext(ctx, "/opt/dolphin/tts/piper/piper", "-m", "/opt/dolphin/tts/en_US-lessac-medium.onnx", "-f", out,
			"--length_scale", strconv.FormatFloat(1/numIn(in, "speed", 1, 0.5, 2), 'f', 2, 64))
		cmd.Stdin = strings.NewReader(prompt)
		meta["voice"], estimate = "en_US-lessac-medium", 2+float64(len(prompt))/200
	case "sfx":
		dur := numIn(in, "duration", 5, 1, 10)
		out, mime = filepath.Join(tmp, "out.wav"), "audio/wav"
		cmd = exec.CommandContext(ctx, "/opt/dolphin/audio/venv/bin/python", "-u", "/opt/dolphin/audio/gen2.py", "sfx", prompt, strconv.FormatFloat(dur, 'f', 1, 64), out)
		meta["duration"], estimate = dur, 60
	case "video":
		frames := numIn(in, "frames", 16, 8, 24)
		out, mime = filepath.Join(tmp, "out.mp4"), "video/mp4"
		cmd = exec.CommandContext(ctx, "/opt/dolphin/audio/venv/bin/python", "-u", "/opt/dolphin/audio/gen2.py", "video", prompt, strconv.Itoa(int(frames)), out)
		meta["frames"], meta["fps"], meta["size"], estimate = int(frames), 8, "256x256", 300
	}
	cmd.Env = append(cmd.Env, os.Environ()...)
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr = pw, pw
	var tail []string
	done := make(chan struct{})
	phase := 0
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Split(scanCRLF)
		for sc.Scan() {
			l := sc.Text()
			if strings.HasPrefix(l, "PROGRESS ") {
				if n, err := strconv.Atoi(strings.TrimSpace(l[9:])); err == nil {
					prog(n * 95 / 100)
				}
				continue
			}
			if t == "image" { // phased so the bar moves smoothly: load 0-40, sampling 40-90, decode 90-99
				ll := strings.ToLower(l)
				if strings.Contains(ll, "sampling") {
					phase = 1
				} else if strings.Contains(ll, "decod") {
					phase = 2
				}
				if m := progRe.FindStringSubmatch(l); m != nil {
					a, _ := strconv.Atoi(m[1])
					b, _ := strconv.Atoi(m[2])
					if b > 0 && a <= b {
						prog([]int{0, 40, 90}[phase] + a*[]int{40, 50, 9}[phase]/b)
					}
				}
			}
			tail = append(tail, l)
			if len(tail) > 20 {
				tail = tail[1:]
			}
		}
		close(done)
	}()
	t0 := time.Now()
	stop := make(chan struct{})
	go func() { // time-based progress fallback
		for {
			select {
			case <-stop:
				return
			case <-time.After(time.Second):
				prog(int(90 * (1 - 1/(1+time.Since(t0).Seconds()/estimate))))
			}
		}
	}()
	err := cmd.Run()
	pw.Close()
	<-done
	close(stop)
	if err != nil {
		return nil, fmt.Errorf("%s generation failed: %s", t, lastLine(strings.Join(tail, "\n")))
	}
	b, err := os.ReadFile(out)
	if err != nil || len(b) == 0 {
		return nil, fmt.Errorf("no %s output produced", t)
	}
	meta["bytes"] = len(b)
	return map[string]any{"mime": mime, "b64": base64.StdEncoding.EncodeToString(b), "meta": meta}, nil
}

func scanCRLF(data []byte, atEOF bool) (int, []byte, error) {
	for i, c := range data {
		if c == '\n' || c == '\r' {
			return i + 1, data[:i], nil
		}
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

// OpenAI-style TTS: POST /v1/audio/speech {"input":"…"} → audio/wav
func handleSpeech(w http.ResponseWriter, r *http.Request, k *Key) {
	var in map[string]any
	if json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in) != nil {
		errJSON(w, 400, "invalid JSON")
		return
	}
	s, _ := in["input"].(string)
	if s == "" {
		s, _ = in["prompt"].(string)
	}
	in["prompt"] = s
	if strings.TrimSpace(s) == "" || len(s) > 4000 {
		errJSON(w, 400, "input required (max 4000 chars)")
		return
	}
	if !hasScope(k, "audio") {
		errJSON(w, 403, "key lacks scope audio")
		return
	}
	if !ttsReady() {
		errJSON(w, 503, "speech is not installed on this server")
		return
	}
	t0 := time.Now()
	res, err := runMedia(r.Context(), "speech", in, func(int) {})
	j := &mediaJob{ID: "sync_" + randB62(8), Type: "speech", in: in, keyName: k.Name, Seconds: time.Since(t0).Seconds()}
	logMedia(j, err)
	if err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	b, _ := base64.StdEncoding.DecodeString(res["b64"].(string))
	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("X-Redx-Seconds", strconv.FormatFloat(j.Seconds, 'f', 2, 64))
	w.Write(b)
}

// ---- media learning log: what was asked, how long it took, whether it worked (no outputs stored) ----
var mediaLogMu sync.Mutex

func logMedia(j *mediaJob, err error) {
	p, _ := j.in["prompt"].(string)
	params := map[string]any{}
	for k, v := range j.in {
		if k != "prompt" && k != "input" && k != "type" {
			params[k] = v
		}
	}
	rec := map[string]any{"kind": "media", "ts": time.Now().Unix(), "job": j.ID, "type": j.Type, "prompt": scrubPII(trunc(p, 500)),
		"params": params, "seconds": j.Seconds, "ok": err == nil, "key": j.keyName}
	if err != nil {
		rec["error"] = trunc(err.Error(), 300)
	}
	if j.Result != nil {
		rec["meta"] = j.Result["meta"]
	}
	b, _ := json.Marshal(rec)
	name := "media-" + time.Now().Format("200601") + ".rxml"
	sealed, e := rxSeal(b, "ml:"+name)
	if e != nil {
		return
	}
	mediaLogMu.Lock()
	defer mediaLogMu.Unlock()
	os.MkdirAll(filepath.Join(rxDir, "learning"), 0700)
	if f, e := os.OpenFile(filepath.Join(rxDir, "learning", name), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600); e == nil {
		f.WriteString(hex.EncodeToString(sealed) + "\n")
		f.Close()
	}
}

func readMediaLog(n int) []map[string]any {
	var out []map[string]any
	fs, _ := filepath.Glob(filepath.Join(rxDir, "learning", "media-*.rxml"))
	sort.Strings(fs)
	for _, f := range fs {
		fh, err := os.Open(f)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 1<<20), 4<<20)
		for sc.Scan() {
			b, err := hex.DecodeString(strings.TrimSpace(sc.Text()))
			if err != nil {
				continue
			}
			if pt, err := rxOpen(b, "ml:"+filepath.Base(f)); err == nil {
				var m map[string]any
				if json.Unmarshal(pt, &m) == nil {
					out = append(out, m)
				}
			}
		}
		fh.Close()
	}
	if len(out) > n {
		out = out[len(out)-n:]
	}
	return out
}

func mediaLogAdmin(w http.ResponseWriter, r *http.Request, p string) bool {
	if p != "/admin/learning/media" || r.Method != "GET" {
		return false
	}
	n, _ := strconv.Atoi(r.URL.Query().Get("n"))
	if n <= 0 || n > 1000 {
		n = 50
	}
	recs := readMediaLog(n)
	stats := map[string]map[string]float64{}
	for _, m := range recs {
		t := fmt.Sprint(m["type"])
		if stats[t] == nil {
			stats[t] = map[string]float64{}
		}
		stats[t]["count"]++
		if m["ok"] == true {
			stats[t]["ok"]++
			s, _ := m["seconds"].(float64)
			stats[t]["total_seconds"] += s
		}
	}
	for _, s := range stats {
		if s["ok"] > 0 {
			s["avg_seconds"] = s["total_seconds"] / s["ok"]
		}
	}
	json.NewEncoder(w).Encode(map[string]any{"data": recs, "stats": stats, "ready": map[string]bool{
		"image": jobReady("image"), "music": jobReady("music"), "speech": jobReady("speech"), "sfx": jobReady("sfx"), "video": jobReady("video")}})
	return true
}
