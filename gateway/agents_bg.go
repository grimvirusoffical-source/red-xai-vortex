package main

// Persistent background agents: run server-side (this node / Cloud PC) until the user turns them off.
// Each agent has its own chat history; users can chat with an agent directly. Survives app close and
// gateway restarts (state in /etc/dolphin/gateway/agents.json).

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type agentTurn struct {
	Role string `json:"role"`
	Text string `json:"content"`
	T    int64  `json:"t"`
	Bg   bool   `json:"background,omitempty"`
}

type bgAgent struct {
	ID        string      `json:"id"`
	KeyID     string      `json:"key_id"`
	Name      string      `json:"name"`
	Model     string      `json:"model"`
    Planner string      `json:"planner,omitempty"`
	System    string      `json:"system"`
	Goal      string      `json:"goal"`
	IntervalS int         `json:"interval_s"`
	On        bool        `json:"on"`
	RunOn     string      `json:"run_on"` // "server" | "cloudpc"
    Permissions []string `json:"permissions,omitempty"`
    AlwaysAllow bool `json:"allow_actions,omitempty"`
    Pending *agentWorkerJob `json:"pending,omitempty"`
	Status    string      `json:"status"`
	LastRun   int64       `json:"last_run"`
	Runs      int         `json:"runs"`
	Unread    int         `json:"unread"`
	LastError string      `json:"last_error,omitempty"`
	History   []agentTurn `json:"history"`
}

var (
	agMu   sync.Mutex
	agents = map[string]*bgAgent{}
	agOnce sync.Once
	agBusy = map[string]bool{}
	agFile = dir + "/agents.json"
)

func agStart() {
	agOnce.Do(func() {
		agMu.Lock()
		agLoad()
		for _, a := range agents {
			if a.Status == "running" {
				a.Status = "queued"
			}
		}
		agMu.Unlock()
		go agLoop()
	})
}

// start background agents at boot so they keep running with no client connected
func init() { go func() { time.Sleep(8 * time.Second); agStart() }() }

func agLoad() {
	b, err := os.ReadFile(agFile)
	if err == nil {
		var l []*bgAgent
		if json.Unmarshal(b, &l) == nil {
			for _, a := range l {
				agents[a.ID] = a
			}
		}
	}
}

func agSaveLocked() {
	l := make([]*bgAgent, 0, len(agents))
	for _, a := range agents {
		l = append(l, a)
	}
	b, _ := json.MarshalIndent(l, "", " ")
	os.WriteFile(agFile+".tmp", b, 0600)
	os.Rename(agFile+".tmp", agFile)
}

func agMsgs(a *bgAgent, extra string) []msg {
	sys := a.System
	if sys == "" {
		sys = "You are " + a.Name + ", a Red-XAI Vortex agent."
	}
	if a.Goal != "" {
		sys += "\n\nYour standing goal: " + a.Goal
	}
	m := []msg{{Role: "system", Content: sys}}
	h := a.History
	if len(h) > 24 {
		h = h[len(h)-24:]
	}
	for _, t := range h {
		m = append(m, msg{Role: t.Role, Content: t.Text})
	}
	if extra != "" {
		m = append(m, msg{Role: "user", Content: extra})
	}
	return m
}

func agAppend(a *bgAgent, t ...agentTurn) {
	a.History = append(a.History, t...)
	if len(a.History) > 400 {
		a.History = a.History[len(a.History)-400:]
	}
}

// Long-lived background jobs must still honor the key's current chat and
// model grants after that key is revoked, disabled, or expires.
func agAuthorized(a *bgAgent) bool {
    mu.Lock()
    defer mu.Unlock()
    for _, k := range keys {
        if k.ID != a.KeyID { continue }
        if k.Revoked != 0 || k.Disabled || (k.Expires > 0 && time.Now().Unix() > k.Expires) { return false }
        return hasScope(k, "chat") && modelOK(k, a.Model)
    }
    return false
}

func agStep(id string) {
	agMu.Lock()
	a := agents[id]
	if a == nil || !a.On || agBusy[id] {
		agMu.Unlock()
		return
	}
    if !agAuthorized(a) {
        a.On = false
        a.Status = "blocked"
        a.LastError = "Agent stopped: its API key no longer allows this model or chat scope."
        agSaveLocked()
        agMu.Unlock()
        return
    }
    // A Cloud PC job needs an actual task worker. The gateway is a model
    // server, not a substitute for the computer in that remote desktop.
    if a.RunOn == "cloudpc" {
        a.Status = "waiting_worker"
        agSaveLocked()
        agMu.Unlock()
        return
    }
	agBusy[id] = true
	a.Status = "running"
	model := a.Model
	tick := fmt.Sprintf("[background run %d, %s] Continue working toward your goal. Report concrete progress briefly; say DONE if finished.", a.Runs+1, time.Now().UTC().Format(time.RFC3339))
	m := agMsgs(a, tick)
	agMu.Unlock()
	out, err := agChatRetry(model, m, 700)
	agMu.Lock()
	defer agMu.Unlock()
	agBusy[id] = false
	if a = agents[id]; a == nil {
		return
	}
	now := time.Now().Unix()
	a.LastRun, a.Runs = now, a.Runs+1
	if err != nil {
		a.Status, a.LastError = "error", err.Error()
		notify(a.KeyID, "agent", "Agent "+a.Name+" hit an error", err.Error(), a.ID)
		log.Printf("agent %s run failed: %v", a.ID, err)
	} else {
		out = strings.TrimSpace(thinkRe.ReplaceAllString(out, ""))
		agAppend(a, agentTurn{"user", tick, now, true}, agentTurn{"assistant", out, now, true})
		a.Unread++
		a.Status = "idle"
		if strings.Contains(out, "DONE") {
			a.On, a.Status = false, "done"
			notify(a.KeyID, "agent", "Agent "+a.Name+" finished", out, a.ID)
		} else {
			notify(a.KeyID, "agent", "New reply from "+a.Name, out, a.ID)
		}
	}
	agSaveLocked()
}

func agLoop() {
	for {
		time.Sleep(10 * time.Second)
		agMu.Lock()
		var due []string
		now := time.Now().Unix()
		for id, a := range agents {
			iv := a.IntervalS
			if iv < 30 {
				iv = 30
			}
			if a.On && !agBusy[id] && now-a.LastRun >= int64(iv) {
				due = append(due, id)
			}
		}
		agMu.Unlock()
		for _, id := range due {
			go agStep(id)
		}
	}
}

func canCloudPC(k *Key) bool {
	if k.Admin || k.Role == "owner" || k.Role == "admin" {
		return true
	}
	for _, s := range k.Scopes {
		if s == "cloudpc" {
			return true
		}
	}
	return false
}

func handleAgents(w http.ResponseWriter, r *http.Request, k *Key) {
	agStart()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	enc := json.NewEncoder(w)
	fail := func(c int, s string) { w.WriteHeader(c); enc.Encode(map[string]any{"error": s}) }
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/v1/agents"), "/"), "/")
	id, act := parts[0], ""
	if len(parts) > 1 {
		act = parts[1]
	}
	var in map[string]any
	if r.Method == "POST" || r.Method == "PUT" {
		json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in)
	}
	str := func(f string) (string, bool) { v, ok := in[f].(string); return v, ok }
    // Worker endpoints perform their own locking, key ownership and lease checks.
    if id=="worker" { handleAgentWorker(w,r,k,act);return }
	agMu.Lock()
	defer agMu.Unlock()
	if id == "" && r.Method == "GET" {
		l := []bgAgent{}
		for _, a := range agents {
			if a.KeyID == k.ID {
				c := *a
				c.History = nil
				l = append(l, c)
			}
		}
		sort.Slice(l, func(i, j int) bool { return l[i].Name < l[j].Name })
		enc.Encode(map[string]any{"object": "list", "data": l})
		return
	}
	if id == "" && r.Method == "POST" {
		nid, _ := str("id")
		if nid == "" {
			nid = "ag_" + randB62(10)
		}
		previous := agents[nid]
		if previous != nil && previous.KeyID != k.ID {
			fail(403, "not your agent")
			return
		}
        // Work on a copy: an invalid update must never mutate the live agent.
        var a *bgAgent
        if previous==nil {
            a=&bgAgent{ID:nid,KeyID:k.ID,Model:"vortex",IntervalS:300,RunOn:"server",Status:"idle"}
        } else { cp:=*previous; a=&cp }
		if v, ok := str("name"); ok {
			a.Name = v
		}
		if v, ok := str("model"); ok && v != "" {
			a.Model = v
		}
        if v, ok := str("planner"); ok {a.Planner=v}
		if v, ok := str("system"); ok {
			a.System = v
		}
		if v, ok := str("goal"); ok {
			a.Goal = v
		}
		if v, ok := in["interval_s"].(float64); ok {
			a.IntervalS = int(v)
		}
		if v, ok := str("run_on"); ok {
			if v == "cloudpc" && !canCloudPC(k) {
				fail(403, "Cloud PC access not approved for this account; request it in the Hub")
				return
			}
			a.RunOn = v
		}
		if v, ok := in["on"].(bool); ok {
			a.On = v
		}
        if v, ok := in["allow_actions"].(bool); ok { a.AlwaysAllow = v }
        if list, supplied := in["permissions"]; supplied {
            raw, ok := list.([]any)
            if !ok || len(raw)>8 {fail(400,"invalid permission list");return}
            a.Permissions=[]string{}
            for _, v:=range raw {
                item,ok:=v.(string)
                if !ok || (item!="web" && item!="files-read" && item!="files-write" && item!="shell" && item!="browser"){
                    fail(400,"unknown remote permission");return
                }
                a.Permissions=append(a.Permissions,item)
            }
        }
        if !hasScope(k,"chat") || !modelOK(k,a.Model) ||
            (a.Planner!="" && !modelOK(k,a.Planner)) {
            fail(403,"API key lacks chat scope or permission for this model or planner");return
        }
        if a.IntervalS<30 || a.IntervalS>86400 {
            fail(400,"run interval must be between 30 seconds and 24 hours");return
        }
        if a.RunOn!="server" && a.RunOn!="cloudpc" {
            fail(400,"run_on must be server or cloudpc");return
        }
        if a.RunOn=="cloudpc" {
            if !canCloudPC(k) {fail(403,"Cloud PC permission is required");return}
            if a.On && !workerOnline(k.ID,time.Now()) {
                fail(409,"No authenticated Cloud PC worker is online for this key");return
            }
        } else if a.AlwaysAllow || len(a.Permissions)>0 {
            fail(400,"server-only model agents cannot execute computer tools");return
        }
        if a.On && strings.TrimSpace(a.Goal)=="" {
            fail(400,"a running agent needs a standing goal");return
        }
		if a.Name == "" {a.Name = "Agent"}
		agents[nid] = a
		agSaveLocked()
		enc.Encode(a)
		return
	}
	a := agents[id]
	if a == nil || a.KeyID != k.ID {
		fail(404, "no such agent")
		return
	}
	switch {
	case act == "" && r.Method == "GET", act == "history":
		a.Unread = 0
		agSaveLocked()
		enc.Encode(a)
	case act == "" && r.Method == "DELETE":
        delete(agBusy,id)
		delete(agents, id)
		agSaveLocked()
		enc.Encode(map[string]any{"deleted": id})
	case act == "toggle" && r.Method == "POST":
		on, ok := in["on"].(bool)
        if !ok {fail(400,"on must be a boolean");return}
        if on && (!hasScope(k,"chat") || !modelOK(k,a.Model)){
            fail(403,"key no longer permits agent model or chat scope");return
        }
        if on && a.RunOn=="cloudpc" && !workerOnline(k.ID,time.Now()){
            fail(409,"Cloud PC worker is offline");return
        }
		a.On = on
		if on {
			a.LastRun = 0
			a.Status = "queued"
		} else {
            a.Pending=nil
            agBusy[id]=false
			a.Status = "off"
		}
		agSaveLocked()
		enc.Encode(a)
	case act == "chat" && r.Method == "POST":
		text, _ := str("content")
		if strings.TrimSpace(text) == "" {
			fail(400, "content required")
			return
		}
		m := agMsgs(a, text)
		model := a.Model
		agMu.Unlock()
		out, err := agChatRetry(model, m, 1500)
		agMu.Lock()
		if err != nil {
			fail(502, err.Error())
			return
		}
		out = strings.TrimSpace(thinkRe.ReplaceAllString(out, ""))
		now := time.Now().Unix()
		if a = agents[id]; a != nil {
			agAppend(a, agentTurn{"user", text, now, false}, agentTurn{"assistant", out, now, false})
			agSaveLocked()
		}
		enc.Encode(map[string]any{"role": "assistant", "content": out})
	default:
		fail(405, "unsupported")
	}
}

// agChatRetry retries when the model was being swapped in/out by the router
// (llama-server returns 500 "Failed to read connection" while a model reloads).
func agChatRetry(model string, m []msg, maxTok int) (string, error) {
	var out string
	var err error
	for i := 0; i < 3; i++ {
		out, _, err = chatOnce(model, m, map[string]any{"max_tokens": maxTok})
		if err == nil || !strings.Contains(err.Error(), "500") {
			return out, err
		}
		time.Sleep(time.Duration(8*(i+1)) * time.Second)
	}
	return out, err
}
