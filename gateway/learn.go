package main

// Vortex learning: while the owner has learning ON and a client sends X-Vortex-Train: 1
// (the app's training mode), chats with whatever model is active are captured (PII scrubbed,
// sealed) as distillation candidates. A judge model scores them; only the best (score >=
// learn_min_score) or thumbs-up/corrected replies are exported to train the Vortex adapter.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type capBuf struct{ bytes.Buffer }

func (c *capBuf) add(b []byte) {
	if c != nil && c.Len() < 2<<20 {
		c.Write(b)
	}
}

func learnWanted(r *http.Request, path string) bool {
	if path != "/v1/chat/completions" || !rxConfig().Learn {
		return false
	}
	h := r.Header.Get("X-Vortex-Train")
	if h == "" {
		h = r.Header.Get("X-RedXAI-Train")
	}
	return h == "1" || strings.EqualFold(h, "true")
}

// answerFrom extracts the assistant text from a JSON or SSE body.
func answerFrom(b []byte, stream bool) string {
	if !stream {
		var o struct {
			Choices []struct {
				Message struct{ Content any } `json:"message"`
			} `json:"choices"`
		}
		if json.Unmarshal(b, &o) == nil && len(o.Choices) > 0 {
			return textOf(o.Choices[0].Message.Content)
		}
		return ""
	}
	var sb strings.Builder
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 1<<20), 4<<20)
	for sc.Scan() {
		l := strings.TrimPrefix(strings.TrimSpace(sc.Text()), "data: ")
		var o struct {
			Choices []struct {
				Delta struct{ Content string } `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(l), &o) == nil && len(o.Choices) > 0 {
			sb.WriteString(o.Choices[0].Delta.Content)
		}
	}
	return sb.String()
}

func distillCapture(model string, body map[string]any, answer string) {
	answer = strings.TrimSpace(thinkRe.ReplaceAllString(answer, ""))
	if answer == "" {
		return
	}
	msgs, _ := body["messages"].([]any)
	if len(msgs) == 0 {
		return
	}
	rec := map[string]any{"kind": "distill", "teacher": model, "messages": scrubAny(msgs), "response": scrubPII(answer)}
	b, _ := json.Marshal(rec["messages"])
	rec["id"] = rxID(string(b) + "\x00" + rec["response"].(string))
	go appendDataset(rec)
}

// ---- scores (no content, just id -> judge score) ----
var scoreMu sync.Mutex

func scorePath() string { return filepath.Join(rxDir, "distill-scores.json") }
func loadScores() map[string]float64 {
	m := map[string]float64{}
	if b, err := os.ReadFile(scorePath()); err == nil {
		json.Unmarshal(b, &m)
	}
	return m
}

var scoreRe = regexp.MustCompile(`\b(10|[1-9])\b`)

func judgeScore(judge string, rec map[string]any) (float64, error) {
	q, _ := json.Marshal(rec["messages"])
	prompt := fmt.Sprintf("Rate the ASSISTANT REPLY to this conversation for correctness, helpfulness and clarity on a 1-10 scale. Reply with only the number.\n\nCONVERSATION:\n%s\n\nASSISTANT REPLY:\n%s", trunc(string(q), 6000), trunc(fmt.Sprint(rec["response"]), 6000))
	out, _, err := chatOnce(judge, []msg{{Role: "user", Content: prompt}}, map[string]any{"max_tokens": 2048, "temperature": 0})
	if err != nil {
		return 0, err
	}
	m := scoreRe.FindString(thinkRe.ReplaceAllString(out, ""))
	if m == "" {
		return 0, fmt.Errorf("no score")
	}
	return strconv.ParseFloat(m, 64)
}

func trunc(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func distillScore(limit int) (int, error) {
	scoreMu.Lock()
	defer scoreMu.Unlock()
	sc := loadScores()
	judge := rxConfig().Base
	n := 0
	for _, d := range readDataset() {
		if d["kind"] != "distill" || n >= limit {
			continue
		}
		id, _ := d["id"].(string)
		if _, done := sc[id]; done || id == "" {
			continue
		}
		s, err := judgeScore(judge, d)
		if err != nil {
			continue
		}
		sc[id] = s
		n++
	}
	b, _ := json.Marshal(sc)
	return n, os.WriteFile(scorePath(), b, 0600)
}

func distillStats() map[string]any {
	sc := loadScores()
	min := rxConfig().LearnMinScore
	tot, scored, best := 0, 0, 0
	teachers := map[string]int{}
	for _, d := range readDataset() {
		if d["kind"] != "distill" {
			continue
		}
		tot++
		teachers[fmt.Sprint(d["teacher"])]++
		if s, ok := sc[fmt.Sprint(d["id"])]; ok {
			scored++
			if s >= min {
				best++
			}
		}
	}
	return map[string]any{"learning_on": rxConfig().Learn, "captured": tot, "scored": scored, "best": best, "min_score": min, "teachers": teachers, "at": time.Now().Unix()}
}
