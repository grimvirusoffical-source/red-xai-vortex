package bridge

import (
    "fmt"
    "os"
    "path/filepath"
    "strings"
    "time"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

var validAgentPermissions = map[string]bool{
    "web": true, "files-read": true, "files-write": true, "shell": true,
}
const agentContinuousDelay = 15 * time.Second

func (s *Server) agentKillPath() string { return filepath.Join(s.St.Dir, "agent-emergency-stop") }
func (s *Server) agentsStopped() bool {
    _, err := os.Stat(s.agentKillPath())
    return err == nil
}
func (s *Server) markAgentsStopped(value bool) error {
    if value { return os.WriteFile(s.agentKillPath(), []byte("stopped\n"), 0600) }
    if err := os.Remove(s.agentKillPath()); err != nil && !os.IsNotExist(err) { return err }
    return nil
}

func configuredAgentPermissions(in map[string]any, previous []string) ([]string,error) {
    raw, supplied := in["permissions"]
    if !supplied { return previous,nil } // old saved agents keep their tools
    values, ok := raw.([]any)
    if !ok { return nil,fmt.Errorf("permissions must be a list") }
    if len(values) > len(validAgentPermissions) { return nil,fmt.Errorf("too many permissions") }
    result := []string{}
    seen := map[string]bool{}
    for _, v := range values {
        p, ok := v.(string)
        if !ok || !validAgentPermissions[p] { return nil,fmt.Errorf("invalid agent permission") }
        if !seen[p] { result=append(result,p); seen[p]=true }
    }
    return result,nil
}

func (s *Server) saveUnifiedAgent(in map[string]any) map[string]any {
    name := strings.TrimSpace(str(in,"name"))
    if name=="" || len(name)>100 { return map[string]any{"ok":false,"message":"Agent name must contain 1–100 characters."} }
    id:=str(in,"id")
    var a store.Agent
    found:=false
    for _, item:=range s.St.Agents { if item.ID==id && id!="" { a=item; found=true; break } }
    if id!="" && !found { return map[string]any{"ok":false,"message":"This agent does not exist. Refresh the list."} }
    if !found {
        id=fmt.Sprintf("agent-%d",time.Now().UnixNano())
        a=store.Agent{ID:id,Created:time.Now(),Provider:"vortex",Model:"vortex",ModelMode:"auto",
            PCControlOn:false,ToolsOn:true,Permissions:[]string{"web","files-read"}}
    }
    a.Name=name
    if _,ok:=in["instructions"];ok { a.SystemPrompt=str(in,"instructions") }
    if _,ok:=in["systemPrompt"];ok { a.SystemPrompt=str(in,"systemPrompt") }
    if len(a.SystemPrompt)>20000 { return map[string]any{"ok":false,"message":"Instructions are too long."} }
    if _,ok:=in["goal"];ok { a.Goal=str(in,"goal") }
    if len(a.Goal)>10000 { return map[string]any{"ok":false,"message":"Goal is too long."} }
    if v,ok:=in["provider"].(string);ok { a.Provider=v }
    if a.Provider=="" { a.Provider="vortex" }
    switch a.Provider { case "vortex","openai","anthropic","google","xai","openrouter","ollama","openai_compat":
    default: return map[string]any{"ok":false,"message":"Choose a supported AI provider."} }
    if v,ok:=in["model"].(string);ok { a.Model=strings.TrimSpace(v) }
    if a.Model=="" { a.Model="vortex" }
    if v,ok:=in["modelMode"].(string);ok { a.ModelMode=v }
    if a.ModelMode=="" { a.ModelMode="single" }
    if a.ModelMode!="single" && a.ModelMode!="auto" && a.ModelMode!="mix" {
        return map[string]any{"ok":false,"message":"Unknown model selection mode."}
    }
    if a.Provider!="vortex" && a.ModelMode!="single" {
        return map[string]any{"ok":false,"message":"Multi-model Vortex routing needs a Vortex provider. An external model is available in Single mode."}
    }
    if pool,ok:=in["modelPool"].([]any);ok {
        a.ModelPool=[]string{}
        for _,v:=range pool {
            if model,ok:=v.(string);ok && len(model)>0 && len(model)<130 {
                a.ModelPool=append(a.ModelPool,model)
            }else { return map[string]any{"ok":false,"message":"Invalid model pool selection."} }
        }
    }
    if v,ok:=in["baseURL"].(string);ok { a.BaseURL=strings.TrimSpace(v) }
    if v,ok:=in["pcControlOn"].(bool);ok { a.PCControlOn=v }
    if v,ok:=in["toolsOn"].(bool);ok { a.ToolsOn=v }
    perms,err:=configuredAgentPermissions(in,a.Permissions)
    if err!=nil { return map[string]any{"ok":false,"message":err.Error()} }
    a.Permissions=perms
    if v,ok:=in["scheduleSeconds"].(float64);ok {
        if v < 0 || v>86400 || (v>0 && v<15) || v!=float64(int(v)) {
            return map[string]any{"ok":false,"message":"Schedule must be 0 (manual), 15 (continuous), or 30–86400 seconds."}
        }
        a.ScheduleS=int(v)
    }
    if v,ok:=in["nonstop"].(bool);ok { a.Nonstop=v }
    if a.Nonstop { a.ScheduleS=15 }
    if v,ok:=in["running"].(bool);ok { a.Running=v }
    if v,ok:=in["runOn"].(string);ok { a.RunOn=strings.TrimSpace(v) }
    switch agentRemoteMode(a) {
    case "local", "server":
    case "cloudpc":
        if a.Provider!="vortex" {return map[string]any{"ok":false,"message":"Cloud PC worker currently uses Vortex gateway models; external API providers run locally."}}
    default:
        return map[string]any{"ok":false,"message":"Run on must be Local, Server, or a connected Cloud PC worker."}
    }
    if a.Running && (a.ScheduleS==0 || strings.TrimSpace(a.Goal)=="") {
        return map[string]any{"ok":false,"message":"Scheduled agents need a goal and run frequency."}
    }
    if v,ok:=in["alwaysAllow"].(bool);ok {
        if v && in["__localOperator"]!=true {
            return map[string]any{"ok":false,"message":"Unattended tool permissions can only be granted at this computer."}
        }
        a.AlwaysAllow=v
    }
    if a.AlwaysAllow && !a.PCControlOn {
        return map[string]any{"ok":false,"message":"Unattended PC actions require PC control to be enabled."}
    }
    if a.Running && s.agentsStopped() {
        return map[string]any{"ok":false,"message":"Emergency stop is active. Reset it explicitly before enabling a schedule."}
    }
    if len(a.Permissions)==0 { a.ToolsOn=false }
    if a.Provider!="vortex" {
        if key:=strings.TrimSpace(str(in,"apiKey"));key!="" {
            if err:=keyring.Set("agent-key-"+a.ID,key);err!=nil {return map[string]any{"ok":false,"message":"Could not securely save provider key."}}
        }
        if keyring.Get("agent-key-"+a.ID)=="" {
            // Local Ollama is allowed with no key; external providers must be configured.
            if a.Provider!="ollama" {return map[string]any{"ok":false,"message":"Provide this external provider's API key; it is stored only locally."}}
        }
    }
    if agentRemoteMode(a)=="server" {
        if err:=s.syncServerAgent(a);err!=nil {
            return map[string]any{"ok":false,"message":err.Error()}
        }
    } else if agentRemoteMode(a)=="cloudpc" {
        if err:=s.syncCloudAgent(a);err!=nil {
            return map[string]any{"ok":false,"message":err.Error()}
        }
    }
    a.Updated=time.Now()
    s.St.SaveAgent(a)
    return map[string]any{"ok":true,"id":a.ID,"message":"Saved "+a.Name+". Changes apply to the next run."}
}

func (s *Server) agentToggle(in map[string]any) map[string]any {
    id:=str(in,"id")
    enabled,ok:=in["running"].(bool)
    if !ok { return map[string]any{"ok":false,"message":"Running must be true or false."} }
    for _,a:=range s.St.Agents {
        if a.ID!=id {continue}
        if enabled && (s.agentsStopped() || a.ScheduleS<=0 || a.Goal=="") {
            return map[string]any{"ok":false,"message":"Clear Emergency Stop and set a schedule and goal before starting."}
        }
        if agentRemoteMode(a)=="server" || agentRemoteMode(a)=="cloudpc" {
            if err:=s.toggleServerAgent(a.ID,enabled);err!=nil {
                return map[string]any{"ok":false,"message":"Remote agent could not change state: "+err.Error()}
            }
        }
        a.Running=enabled
        a.Updated=time.Now()
        if enabled { a.LastRun=time.Time{} }
        s.St.SaveAgent(a)
        if !enabled {s.cancelAgentRuns(id)}
        return map[string]any{"ok":true,"running":enabled}
    }
    return map[string]any{"ok":false,"message":"Unknown agent"}
}

func (s *Server) agentDelete(in map[string]any) map[string]any {
    id:=str(in,"id")
    if id=="vortex-default" || id=="" { return map[string]any{"ok":false,"message":"The default Vortex agent cannot be removed."} }
    for _,a:=range s.St.Agents {
        if a.ID==id && (agentRemoteMode(a)=="server" || agentRemoteMode(a)=="cloudpc") {
            if err:=s.deleteServerAgent(id);err!=nil {
                return map[string]any{"ok":false,"message":"Remote agent was not deleted: "+err.Error()}
            }
        }
    }
    if !s.St.DeleteAgent(id) { return map[string]any{"ok":false,"message":"Unknown agent"} }
    s.cancelAgentRuns(id)
    _=keyring.Set("agent-key-"+id,"")
    return map[string]any{"ok":true}
}

func (s *Server) cancelAgentRuns(agentID string) {
    runs.mu.Lock()
    defer runs.mu.Unlock()
    for _,r:=range runs.runs {
        if r.server==s && r.AgentID==agentID && r.Ended.IsZero() && r.cancel!=nil {
            r.cancel()
        }
    }
}

func (s *Server) agentKillAll(in map[string]any) map[string]any {
    if err:=s.markAgentsStopped(true);err!=nil {
        return map[string]any{"ok":false,"message":"Failed to persist emergency stop."}
    }
    // Interrupt local subprocesses and revoke the PC approval epoch BEFORE
    // any remote network operation. A remote outage cannot delay local Stop.
    count,pcErr:=s.stopPCControl()
    remoteProfiles:=[]store.Agent{}
    for _,a:=range s.St.Agents {
        if a.Running && (agentRemoteMode(a)=="server" || agentRemoteMode(a)=="cloudpc") {
            remoteProfiles=append(remoteProfiles,a)
        } else if a.Running {
            a.Running=false
        }
        if a.AlwaysAllow {a.AlwaysAllow=false}
        s.St.SaveAgent(a)
    }
    markRemoteStopped:=func(id string) {
        for _,a:=range s.St.Agents {
            if a.ID==id && a.Running {
                a.Running=false
                s.St.SaveAgent(a)
                break
            }
        }
    }
    problems:=[]string{}
    result:=s.gw("POST","/agents/stop-all",map[string]any{})
    if result["ok"]==true {
        for _,a:=range remoteProfiles {markRemoteStopped(a.ID)}
    }else{
        for _,a:=range remoteProfiles {
            if err:=s.toggleServerAgent(a.ID,false);err!=nil {
                problems=append(problems,a.Name+": "+err.Error())
            } else {markRemoteStopped(a.ID)}
        }
        if len(problems)==0 {
            problems=append(problems,"Gateway-wide cancellation could not be verified: "+fmt.Sprint(result["message"]))
        }
    }
    if pcErr!=nil {
        problems=append(problems,"Local stop policy could not be persisted: "+pcErr.Error())
    }
    if len(problems)>0 {
        return map[string]any{"ok":false,"stopped":count,
            "message":"Local tasks were interrupted. Check remote cancellations and local policy: "+strings.Join(problems,"; ")}
    }
    return map[string]any{"ok":true,"stopped":count,"message":"All local and remote agent schedules stopped; outstanding worker leases were revoked."}
}
func (s *Server) agentResume(in map[string]any) map[string]any {
    if in["__localOperator"]!=true {return map[string]any{"ok":false,"message":"Only the local operator may reset Emergency Stop."}}
    if err:=s.markAgentsStopped(false);err!=nil{return map[string]any{"ok":false,"message":err.Error()}}
    return map[string]any{"ok":true,"message":"Emergency Stop reset. Agents stay paused until you start them."}
}

func agentDue(a store.Agent, now time.Time) bool {
    if !a.Running || a.ScheduleS<15 || a.Goal=="" {return false}
    duration:=time.Duration(a.ScheduleS)*time.Second
    if a.Nonstop {duration=agentContinuousDelay}
    return a.LastRun.IsZero() || !now.Before(a.LastRun.Add(duration))
}

func (s *Server) agentScheduleLoop() {
    ticker:=time.NewTicker(5*time.Second)
    defer ticker.Stop()
    for range ticker.C {
        s.agentScheduleStep(time.Now())
    }
}
func (s *Server) agentScheduleStep(now time.Time) {
    if s.agentsStopped() {return}
    for _,a:=range s.St.Agents {
        if agentRemoteMode(a)!="local" || !agentDue(a,now) {continue}
        if requiresDesktopBrowser(a.Goal) {
            // No browser DOM adapter is installed in the Go desktop. Do not
            // enter text into a random search box or simulate messages.
            a.Running=false
            s.St.SaveAgent(a)
            continue
        }
        runs.mu.Lock()
        active:=false
        for _,r:=range runs.runs {
            if r.server==s && r.AgentID==a.ID && r.Ended.IsZero() {active=true;break}
        }
        runs.mu.Unlock()
        if active {continue}
        a.LastRun=now
        s.St.SaveAgent(a)
        _=s.startRunFrom(a.ID,a.Goal,"",true)
    }
}
