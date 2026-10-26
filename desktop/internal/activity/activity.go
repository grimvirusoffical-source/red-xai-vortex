// Package activity is the append-only, searchable, exportable agent activity log.
// One JSON object per line in <config>/activity/YYYY-MM.jsonl (0600). Lines are never rewritten.
package activity

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type Event struct {
	TS      time.Time `json:"ts"`
	Seq     int64     `json:"seq"`
	RunID   string    `json:"runID,omitempty"`
	AgentID string    `json:"agentID"`
	Agent   string    `json:"agent"`
	Kind    string    `json:"kind"` // run.start, think, tool.call, tool.result, approval.request, approval.allow, approval.deny, run.end, error, chat
	Tool    string    `json:"tool,omitempty"`
	Summary string    `json:"summary"`
	Detail  string    `json:"detail,omitempty"`
	Device  string    `json:"device,omitempty"`
}

type Log struct {
	Dir string
	mu  sync.Mutex
	seq int64
}

func Open(configDir string) *Log {
	d := filepath.Join(configDir, "activity")
	_ = os.MkdirAll(d, 0700)
	return &Log{Dir: d, seq: time.Now().UnixNano()}
}

// secret-looking material is masked before anything is written.
var secretRe = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}`),
	regexp.MustCompile(`\b(sk|pk|rk|xai|gh[pousr]|xox[abpr]|AKIA)[-_A-Za-z0-9]{12,}`),
	regexp.MustCompile(`(?i)((?:password|passwd|secret|token|api[_-]?key|authorization)["']?\s*[:=]\s*["']?)[^\s"',}]+`),
	regexp.MustCompile(`\b[A-Fa-f0-9]{40,}\b`),
	regexp.MustCompile(`\b[A-Za-z0-9+/_\-]{48,}={0,2}`),
}

func Redact(s string) string {
	for i, r := range secretRe {
		if i == 0 || i == 2 {
			s = r.ReplaceAllString(s, "${1}••••")
		} else {
			s = r.ReplaceAllString(s, "••••")
		}
	}
	return s
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

func (l *Log) Append(e Event) Event {
	l.mu.Lock()
	defer l.mu.Unlock()
	if e.TS.IsZero() {
		e.TS = time.Now()
	}
	l.seq++
	e.Seq = l.seq
	if e.Device == "" {
		h, _ := os.Hostname()
		e.Device = h
	}
	e.Summary = clip(Redact(e.Summary), 400)
	e.Detail = clip(Redact(e.Detail), 8000)
	b, _ := json.Marshal(e)
	f, err := os.OpenFile(filepath.Join(l.Dir, e.TS.Format("2006-01")+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err == nil {
		f.Write(append(b, '\n'))
		f.Close()
	}
	return e
}

type Query struct {
	AgentID, RunID, Kind, Q string
	Since                   time.Time
	Limit                   int
}

// Search returns matching events, newest first.
func (l *Log) Search(q Query) []Event {
	files, _ := filepath.Glob(filepath.Join(l.Dir, "*.jsonl"))
	sort.Sort(sort.Reverse(sort.StringSlice(files)))
	if q.Limit <= 0 {
		q.Limit = 500
	}
	ql := strings.ToLower(q.Q)
	var out []Event
	for _, fn := range files {
		var evs []Event
		f, err := os.Open(fn)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64*1024), 1<<20)
		for sc.Scan() {
			var e Event
			if json.Unmarshal(sc.Bytes(), &e) != nil {
				continue
			}
			if q.AgentID != "" && e.AgentID != q.AgentID || q.RunID != "" && e.RunID != q.RunID ||
				q.Kind != "" && !strings.HasPrefix(e.Kind, q.Kind) || !q.Since.IsZero() && e.TS.Before(q.Since) {
				continue
			}
			if ql != "" && !strings.Contains(strings.ToLower(e.Agent+" "+e.Kind+" "+e.Tool+" "+e.Summary+" "+e.Detail), ql) {
				continue
			}
			evs = append(evs, e)
		}
		f.Close()
		for i := len(evs) - 1; i >= 0; i-- {
			out = append(out, evs[i])
			if len(out) >= q.Limit {
				return out
			}
		}
	}
	return out
}

type AgentStat struct {
	AgentID  string    `json:"agentID"`
	Agent    string    `json:"agent"`
	Runs     int       `json:"runs"`
	Actions  int       `json:"actions"`
	Denied   int       `json:"denied"`
	Errors   int       `json:"errors"`
	Last     time.Time `json:"last"`
	LastWhat string    `json:"lastWhat"`
}

// Stats is the global dashboard: per-agent totals over all time.
func (l *Log) Stats() []AgentStat {
	m := map[string]*AgentStat{}
	evs := l.Search(Query{Limit: 1 << 30})
	for i := len(evs) - 1; i >= 0; i-- {
		e := evs[i]
		s := m[e.AgentID]
		if s == nil {
			s = &AgentStat{AgentID: e.AgentID}
			m[e.AgentID] = s
		}
		s.Agent = e.Agent
		switch e.Kind {
		case "run.start":
			s.Runs++
		case "tool.call":
			s.Actions++
		case "approval.deny":
			s.Denied++
		case "error":
			s.Errors++
		}
		s.Last, s.LastWhat = e.TS, e.Summary
	}
	out := []AgentStat{}
	for _, s := range m {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Last.After(out[j].Last) })
	return out
}

// Export writes the matching events (oldest first) as json or csv to path.
func (l *Log) Export(q Query, format, path string) (int, error) {
	q.Limit = 1 << 30
	evs := l.Search(q)
	for i, j := 0, len(evs)-1; i < j; i, j = i+1, j-1 {
		evs[i], evs[j] = evs[j], evs[i]
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if format == "csv" {
		w := csv.NewWriter(f)
		w.Write([]string{"time", "agent", "run", "kind", "tool", "summary", "detail", "device"})
		for _, e := range evs {
			w.Write([]string{e.TS.Format(time.RFC3339), e.Agent, e.RunID, e.Kind, e.Tool, e.Summary, e.Detail, e.Device})
		}
		w.Flush()
		return len(evs), w.Error()
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return len(evs), enc.Encode(evs)
}
