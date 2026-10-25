package main

// Distill / teach job: pick 1–3 source models + a Red-XAI target (vortex / red-xai).
// Sources answer a prompt bank; preferred answers are sealed into the distill dataset,
// scored, exported, and optionally handed to the trainer. Progress is polled via GET.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type distillJob struct {
	ID        string    `json:"id"`
	Sources   []string  `json:"sources"`
	Target    string    `json:"target"`
	Prompts   int       `json:"prompts"`
	Done      int       `json:"done"`
	Captured  int       `json:"captured"`
	Status    string    `json:"status"` // queued|running|exporting|training|done|error
	Message   string    `json:"message"`
	Started   time.Time `json:"started"`
	Finished  time.Time `json:"finished,omitempty"`
	ExportFile string   `json:"export_file,omitempty"`
}

var (
	djMu   sync.Mutex
	djCur  *distillJob
	djHist []*distillJob
)

var defaultTeachPrompts = []string{
	"Explain what Red-XAI Vortex is in two sentences.",
	"Write a correct Python function that returns the nth Fibonacci number iteratively.",
	"How do you safely store an API key on macOS, Windows, and Linux?",
	"Summarize the difference between a merge router and a panel+judge merge.",
	"Give three concrete tips for prompting a coding model.",
	"What is LoRA distillation used for in Vortex?",
	"Draft a short polite email declining a meeting.",
	"List steps to add an OpenAI-compatible provider to an editor.",
	"Explain rate limiting for an API gateway in plain language.",
	"Review this idea: letting users create agents that call PC tools with Allow/Deny. Pros and cons.",
}

func distillJobAdmin(w http.ResponseWriter, r *http.Request, p string, in map[string]any) bool {
	if !strings.HasPrefix(p, "/admin/redxai/distill/job") {
		return false
	}
	if r.Method != "GET" && !requireOwner(w, r) {
		return true
	}
	switch {
	case p == "/admin/redxai/distill/job" && r.Method == "GET":
		djMu.Lock()
		defer djMu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"current": djCur, "history": djHist})
	case p == "/admin/redxai/distill/job" && r.Method == "POST":
		djMu.Lock()
		if djCur != nil && (djCur.Status == "running" || djCur.Status == "queued" || djCur.Status == "exporting" || djCur.Status == "training") {
			djMu.Unlock()
			errJSON(w, 409, "a distill job is already running")
			return true
		}
		srcs, _ := in["sources"].([]any)
		var sources []string
		for _, s := range srcs {
			if x := strings.TrimSpace(fmt.Sprint(s)); x != "" {
				sources = append(sources, x)
			}
		}
		if len(sources) < 1 || len(sources) > 3 {
			djMu.Unlock()
			errJSON(w, 400, "pick 1–3 source models")
			return true
		}
		target := strings.TrimSpace(fmt.Sprint(in["target"]))
		if target == "" {
			target = "vortex"
		}
		n := 8
		if v, ok := in["prompts"].(float64); ok && v >= 1 && v <= 50 {
			n = int(v)
		}
		j := &distillJob{
			ID: "dj-" + randB62(8), Sources: sources, Target: target, Prompts: n,
			Status: "queued", Message: "queued", Started: time.Now(),
		}
		djCur = j
		djMu.Unlock()
		go runDistillJob(j)
		json.NewEncoder(w).Encode(j)
	default:
		errJSON(w, 404, "not found")
	}
	return true
}

func runDistillJob(j *distillJob) {
	set := func(st, msg string) {
		djMu.Lock()
		j.Status = st
		j.Message = msg
		djMu.Unlock()
	}
	set("running", "asking source models…")
	prompts := defaultTeachPrompts
	if j.Prompts < len(prompts) {
		prompts = prompts[:j.Prompts]
	}
	for i, q := range prompts {
		for _, src := range j.Sources {
			out, _, err := chatOnce(src, []msg{{Role: "user", Content: q}}, map[string]any{"max_tokens": 1024, "temperature": 0.3})
			if err != nil {
				set("running", fmt.Sprintf("source %s failed on prompt %d: %v (continuing)", src, i+1, err))
				continue
			}
			out = strings.TrimSpace(thinkRe.ReplaceAllString(out, ""))
			if out == "" {
				continue
			}
			rec := map[string]any{
				"kind": "distill", "teacher": src, "target": j.Target, "preferred": true,
				"job": j.ID, "messages": scrubAny([]any{map[string]any{"role": "user", "content": q}}),
				"response": scrubPII(out),
			}
			b, _ := json.Marshal(rec["messages"])
			rec["id"] = rxID(string(b) + "\x00" + out)
			appendDataset(rec)
			djMu.Lock()
			j.Captured++
			djMu.Unlock()
		}
		djMu.Lock()
		j.Done = i + 1
		j.Message = fmt.Sprintf("prompt %d/%d · %d samples", i+1, len(prompts), j.Captured)
		djMu.Unlock()
	}
	set("exporting", "exporting training JSONL…")
	os.MkdirAll(filepath.Join(rxDir, "export"), 0700)
	name := filepath.Join(rxDir, "export", "distill-job-"+j.ID+".jsonl")
	f, err := os.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		set("error", "export failed: "+err.Error())
		finishJob(j)
		return
	}
	n := 0
	for _, d := range readDataset() {
		if fmt.Sprint(d["job"]) != j.ID {
			continue
		}
		msgs, _ := d["messages"].([]any)
		reply, _ := d["response"].(string)
		if len(msgs) == 0 || reply == "" {
			continue
		}
		all := append([]any{map[string]any{"role": "system", "content": rxConfig().Persona}}, msgs...)
		all = append(all, map[string]any{"role": "assistant", "content": reply})
		b, _ := json.Marshal(map[string]any{"messages": all, "target": j.Target})
		f.Write(append(b, '\n'))
		n++
	}
	f.Close()
	djMu.Lock()
	j.ExportFile = name
	djMu.Unlock()

	// Optional trainer hook (installed on Vultr as redxai-train).
	if _, err := os.Stat("/usr/local/bin/redxai-train"); err == nil {
		set("training", fmt.Sprintf("training %s on %d examples…", j.Target, n))
		cmd := exec.Command("/usr/local/bin/redxai-train", "--target", j.Target, "--data", name)
		if err := cmd.Start(); err == nil {
			_ = cmd.Wait()
		}
	}
	set("done", fmt.Sprintf("captured %d · exported %d → %s", j.Captured, n, j.Target))
	finishJob(j)
}

func finishJob(j *distillJob) {
	djMu.Lock()
	j.Finished = time.Now()
	djHist = append([]*distillJob{j}, djHist...)
	if len(djHist) > 20 {
		djHist = djHist[:20]
	}
	if djCur == j {
		djCur = j // keep as current for UI until next start
	}
	djMu.Unlock()
}
