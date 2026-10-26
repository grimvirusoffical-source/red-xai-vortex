package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/activity"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// Agent action loop: the agent works on a task step by step, calling tools via a
// <tool_call>{"name":…,"arguments":{…}}</tool_call> text protocol (works with every model).
// Reads run on their own; writes and commands wait for Allow/Deny in the app.
// Every step is written to the append-only activity log.

const maxRunSteps = 10

type Approval struct {
	ID      string `json:"id"`
	Tool    string `json:"tool"`
	What    string `json:"what"`
	decided chan bool
}

type Run struct {
	ID      string    `json:"id"`
	AgentID string    `json:"agentID"`
	Agent   string    `json:"agent"`
	Task    string    `json:"task"`
	Status  string    `json:"status"` // running, waiting, done, stopped, error
	Steps   int       `json:"steps"`
	Result  string    `json:"result"`
	Started time.Time `json:"started"`
	Ended   time.Time `json:"ended,omitempty"`
	Pending *Approval `json:"pending,omitempty"`
	ChatID  string    `json:"chatID,omitempty"`
	cancel  context.CancelFunc
}

type runTable struct {
	mu   sync.Mutex
	runs map[string]*Run
}

var runs = runTable{runs: map[string]*Run{}}

type tool struct {
	name, args, desc string
	write            bool
	run              func(ctx context.Context, a map[string]any) (string, error)
}

func homeDir() string { h, _ := os.UserHomeDir(); return h }

// inHome resolves p (supports ~) and refuses anything outside the user's home folder.
func inHome(p string) (string, error) {
	h := homeDir()
	if strings.HasPrefix(p, "~") {
		p = filepath.Join(h, strings.TrimPrefix(p, "~"))
	}
	if !filepath.IsAbs(p) {
		p = filepath.Join(h, p)
	}
	p = filepath.Clean(p)
	if p != h && !strings.HasPrefix(p, h+string(os.PathSeparator)) {
		return "", fmt.Errorf("only files inside your home folder are allowed")
	}
	return p, nil
}

var tagRe = regexp.MustCompile(`(?s)<script.*?</script>|<style.*?</style>|<[^>]+>`)
var wsRe = regexp.MustCompile(`\s{2,}`)

func runTools(pcOn bool) []tool {
	t := []tool{
		{name: "fetch_url", args: "url", desc: "Download a web page and return its text.", run: func(ctx context.Context, a map[string]any) (string, error) {
			u := str(a, "url")
			if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
				u = "https://" + u
			}
			req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
			req.Header.Set("User-Agent", "Red-XAI-Vortex/agent")
			r, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
			if err != nil {
				return "", err
			}
			defer r.Body.Close()
			b, _ := io.ReadAll(io.LimitReader(r.Body, 400<<10))
			txt := wsRe.ReplaceAllString(tagRe.ReplaceAllString(string(b), " "), " ")
			return fmt.Sprintf("HTTP %d\n%s", r.StatusCode, clipS(txt, 6000)), nil
		}},
		{name: "list_dir", args: "path", desc: "List a folder in the user's home (~ allowed).", run: func(ctx context.Context, a map[string]any) (string, error) {
			p, err := inHome(str(a, "path"))
			if err != nil {
				return "", err
			}
			es, err := os.ReadDir(p)
			if err != nil {
				return "", err
			}
			var b strings.Builder
			for i, e := range es {
				if i >= 200 {
					b.WriteString("…\n")
					break
				}
				if e.IsDir() {
					b.WriteString("[dir] " + e.Name() + "\n")
				} else {
					b.WriteString(e.Name() + "\n")
				}
			}
			return b.String(), nil
		}},
		{name: "read_file", args: "path", desc: "Read a text file in the user's home.", run: func(ctx context.Context, a map[string]any) (string, error) {
			p, err := inHome(str(a, "path"))
			if err != nil {
				return "", err
			}
			f, err := os.Open(p)
			if err != nil {
				return "", err
			}
			defer f.Close()
			b, _ := io.ReadAll(io.LimitReader(f, 64<<10))
			return string(b), nil
		}},
		{name: "write_file", args: "path, content", desc: "Create or overwrite a text file in the user's home (asks the user first).", write: true, run: func(ctx context.Context, a map[string]any) (string, error) {
			p, err := inHome(str(a, "path"))
			if err != nil {
				return "", err
			}
			os.MkdirAll(filepath.Dir(p), 0700)
			c := str(a, "content")
			if err := os.WriteFile(p, []byte(c), 0600); err != nil {
				return "", err
			}
			return fmt.Sprintf("wrote %d bytes to %s", len(c), p), nil
		}},
	}
	if pcOn {
		t = append(t, tool{name: "run_command", args: "command", desc: "Run a shell command on this computer (asks the user first; 60 s limit).", write: true, run: func(ctx context.Context, a map[string]any) (string, error) {
			ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
			defer cancel()
			var cmd *exec.Cmd
			if runtime.GOOS == "windows" {
				cmd = exec.CommandContext(ctx, "cmd", "/C", str(a, "command"))
			} else {
				cmd = exec.CommandContext(ctx, "sh", "-c", str(a, "command"))
			}
			cmd.Dir = homeDir()
			out, err := cmd.CombinedOutput()
			s := clipS(string(out), 6000)
			if err != nil {
				return s + "\n(exit: " + err.Error() + ")", nil
			}
			return s, nil
		}})
	}
	return t
}

func clipS(s string, n int) string {
	if len(s) > n {
		return s[:n] + "\n…[truncated]"
	}
	return s
}

func toolPrompt(ts []tool) string {
	var b strings.Builder
	b.WriteString("You are working on a task for the user, step by step, on their computer.\n" +
		"Carry out ordinary requests directly and completely: no unnecessary refusals, hedging, moralizing or disclaimers. The only things you must decline are fraud, mass fake-account creation, and survey/reward farming.\n" +
		"To use a tool reply with ONLY: <tool_call>{\"name\": \"TOOL\", \"arguments\": {...}}</tool_call> (one per reply).\n" +
		"You will get the result in a message starting with TOOL_RESULT. Use results exactly as given; never invent results.\n" +
		"When the task is finished, reply normally with the final answer (no tool_call).\nTools:\n")
	for _, t := range ts {
		b.WriteString("- " + t.name + "(" + t.args + "): " + t.desc + "\n")
	}
	return b.String()
}

var callRe = regexp.MustCompile(`(?s)<tool_call>\s*(\{.*?\})\s*(?:</tool_call>|$)`)

func parseCall(s string) (string, map[string]any, bool) {
	js := ""
	if m := callRe.FindStringSubmatch(s); m != nil {
		js = m[1]
	} else if a, b := strings.Index(s, "{"), strings.LastIndex(s, "}"); a >= 0 && b > a && strings.Contains(s, "\"name\"") {
		js = s[a : b+1]
	}
	if js == "" {
		return "", nil, false
	}
	var o struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if json.Unmarshal([]byte(js), &o) != nil || o.Name == "" {
		return "", nil, false
	}
	return o.Name, o.Arguments, true
}

func (s *Server) log(r *Run, kind, toolName, summary, detail string) {
	s.Act.Append(activity.Event{RunID: r.ID, AgentID: r.AgentID, Agent: r.Agent, Kind: kind, Tool: toolName, Summary: summary, Detail: detail})
}

// startRun launches the loop in the background and returns the run.
func (s *Server) startRun(agentID, task, chatID string) map[string]any {
	task = strings.TrimSpace(task)
	if task == "" {
		return map[string]any{"ok": false, "message": "Type a task for the agent."}
	}
	me := s.memberFor(agentID)
	pcOn := false
	for _, a := range s.St.Agents {
		if a.ID == agentID {
			pcOn = a.PCControlOn
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &Run{ID: fmt.Sprintf("r-%d", time.Now().UnixNano()), AgentID: agentID, Agent: me.Name, Task: task, Status: "running", Started: time.Now(), ChatID: chatID, cancel: cancel}
	runs.mu.Lock()
	runs.runs[r.ID] = r
	runs.mu.Unlock()
	s.log(r, "run.start", "", "Task: "+task, "model "+me.Model)
	go s.loop(ctx, r, me, runTools(pcOn))
	return map[string]any{"ok": true, "run": r}
}

func (s *Server) setRun(r *Run, f func()) { runs.mu.Lock(); f(); runs.mu.Unlock() }

func (s *Server) loop(ctx context.Context, r *Run, me member, ts []tool) {
	sys := toolPrompt(ts)
	if me.System != "" {
		sys = me.System + "\n\n" + sys
	}
	msgs := []map[string]string{{"role": "system", "content": sys}, {"role": "user", "content": r.Task}}
	agentID := r.AgentID
	if strings.HasPrefix(agentID, "model:") {
		agentID = ""
	}
	finish := func(status, result string) {
		s.setRun(r, func() { r.Status, r.Result, r.Ended, r.Pending = status, result, time.Now(), nil })
		s.log(r, "run.end", "", status+": "+clipS(result, 300), result)
		if r.ChatID != "" {
			s.appendChat(r.ChatID, me.Name, "**Task "+status+"** ("+fmt.Sprint(r.Steps)+" steps): "+result)
		}
	}
	for step := 0; step < maxRunSteps; step++ {
		if ctx.Err() != nil {
			finish("stopped", "Stopped by you.")
			return
		}
		s.setRun(r, func() { r.Steps = step + 1 })
		out, err := s.complete(agentID, me.Model, msgs, 700)
		if err != nil {
			s.log(r, "error", "", err.Error(), "")
			finish("error", err.Error())
			return
		}
		name, args, ok := parseCall(out)
		if !ok {
			finish("done", strings.TrimSpace(out))
			return
		}
		msgs = append(msgs, map[string]string{"role": "assistant", "content": out})
		var t *tool
		for i := range ts {
			if ts[i].name == name {
				t = &ts[i]
			}
		}
		aj, _ := json.Marshal(args)
		if t == nil {
			s.log(r, "error", name, "Unknown tool "+name, "")
			msgs = append(msgs, map[string]string{"role": "user", "content": "TOOL_RESULT " + name + ":\nerror: no such tool"})
			continue
		}
		s.log(r, "tool.call", name, name+" "+clipS(string(aj), 200), string(aj))
		if t.write {
			ap := &Approval{ID: fmt.Sprintf("ap-%d", time.Now().UnixNano()), Tool: name, What: clipS(string(aj), 600), decided: make(chan bool, 1)}
			s.setRun(r, func() { r.Status, r.Pending = "waiting", ap })
			s.log(r, "approval.request", name, "Waiting for Allow/Deny: "+name, "")
			allow := false
			select {
			case allow = <-ap.decided:
			case <-time.After(10 * time.Minute):
			case <-ctx.Done():
			}
			s.setRun(r, func() { r.Status, r.Pending = "running", nil })
			if !allow {
				s.log(r, "approval.deny", name, "Denied: "+name, "")
				msgs = append(msgs, map[string]string{"role": "user", "content": "TOOL_RESULT " + name + ":\nThe user DENIED this action. Do not retry it; continue without it or finish."})
				continue
			}
			s.log(r, "approval.allow", name, "Allowed: "+name, "")
		}
		res, err := t.run(ctx, args)
		if err != nil {
			res = "error: " + err.Error()
		}
		s.log(r, "tool.result", name, clipS(strings.ReplaceAll(res, "\n", " "), 200), res)
		msgs = append(msgs, map[string]string{"role": "user", "content": "TOOL_RESULT " + name + " (exact):\n" + res})
	}
	finish("done", "(Stopped after the step limit.)")
}

func (s *Server) appendChat(chatID, name, text string) {
	for _, c := range s.St.Chats {
		if c.ID == chatID {
			c.Messages = append(c.Messages, msgOf(name, text))
			c.Updated = time.Now()
			s.St.SaveChat(c)
			return
		}
	}
}

func getRun(id string) *Run { runs.mu.Lock(); defer runs.mu.Unlock(); return runs.runs[id] }

func listRuns() []Run {
	runs.mu.Lock()
	defer runs.mu.Unlock()
	out := []Run{}
	for _, r := range runs.runs {
		c := *r
		if r.Pending != nil {
			p := *r.Pending
			c.Pending = &p
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Started.After(out[j].Started) })
	return out
}

func (s *Server) approve(runID string, allow bool) map[string]any {
	r := getRun(runID)
	if r == nil || r.Pending == nil {
		return map[string]any{"ok": false, "message": "Nothing is waiting for approval."}
	}
	select {
	case r.Pending.decided <- allow:
	default:
	}
	return map[string]any{"ok": true}
}

func (s *Server) stopRun(runID string) map[string]any {
	r := getRun(runID)
	if r == nil {
		return map[string]any{"ok": false, "message": "No such run."}
	}
	r.cancel()
	if r.Pending != nil {
		select {
		case r.Pending.decided <- false:
		default:
		}
	}
	return map[string]any{"ok": true}
}

func (s *Server) activityQuery(in map[string]any) activity.Query {
	q := activity.Query{AgentID: str(in, "agentID"), RunID: str(in, "runID"), Kind: str(in, "kind"), Q: str(in, "q")}
	if l, ok := in["limit"].(float64); ok {
		q.Limit = int(l)
	}
	if d, ok := in["days"].(float64); ok && d > 0 {
		q.Since = time.Now().Add(-time.Duration(d*24) * time.Hour)
	}
	return q
}

func (s *Server) activityExport(in map[string]any) map[string]any {
	f := str(in, "format")
	if f != "csv" {
		f = "json"
	}
	dir := filepath.Join(homeDir(), "Downloads")
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		dir = homeDir()
	}
	p := filepath.Join(dir, "vortex-activity-"+time.Now().Format("20060102-150405")+"."+f)
	n, err := s.Act.Export(s.activityQuery(in), f, p)
	if err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	return map[string]any{"ok": true, "path": p, "count": n}
}

func msgOf(name, text string) store.Msg {
	return store.Msg{Role: "assistant", Name: name, Content: text}
}
