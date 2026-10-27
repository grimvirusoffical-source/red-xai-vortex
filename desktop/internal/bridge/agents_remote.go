package bridge

import (
    "fmt"
    "strings"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// Persistent gateway agents are genuine background *model* workers. Their
// API currently does not expose Cloud PC browser, shell or desktop tools.
// Never silently relabel that as remote computer execution.
func (s *Server) syncServerAgent(a store.Agent) error {
    if a.Provider != "vortex" {
        return fmt.Errorf("persistent server agents currently support Vortex gateway models only")
    }
    if a.PCControlOn || a.AlwaysAllow {
        return fmt.Errorf("server-only workers cannot use local computer permissions; choose Local for PC tools")
    }
    if a.ModelMode == "mix" {
        return fmt.Errorf("multi-model tool planning currently runs on the local desktop; select Single/Auto for server background jobs")
    }
    model:=a.Model
    if a.ModelMode=="auto" || model=="" {model="vortex"}
    seconds:=a.ScheduleS
    if a.Nonstop || seconds<30 {seconds=30}
    result:=s.gw("POST","/agents",map[string]any{
        "id":a.ID,"name":a.Name,"model":model,
        "system":a.SystemPrompt,"goal":a.Goal,
        "interval_s":seconds,"run_on":"server","on":a.Running,
    })
    if result["ok"]!=true {
        return fmt.Errorf("server agent was not updated: %v",result["message"])
    }
    return nil
}
func (s *Server) toggleServerAgent(id string, on bool) error {
    result:=s.gw("POST","/agents/"+id+"/toggle",map[string]any{"on":on})
    if result["ok"]!=true{return fmt.Errorf("%v",result["message"])}
    return nil
}
func (s *Server) deleteServerAgent(id string) error {
    result:=s.gw("DELETE","/agents/"+id,nil)
    if result["ok"]!=true{return fmt.Errorf("%v",result["message"])}
    return nil
}
// Cloud PC agents do not execute on the local desktop. An online worker
// claims gateway-issued leases and reports tool results back to the owner.
func (s *Server) syncCloudAgent(a store.Agent) error {
    if a.Provider!="vortex" {
        return fmt.Errorf("Cloud PC task worker currently supports Vortex gateway models only")
    }
    model,planner:=a.Model,""
    if a.ModelMode=="auto" || a.ModelMode=="mix" {
        if allowed,ok:=s.listModels();ok {
            model,planner=availableAgentModels(a,a.Goal,allowed)
        }else{
            model,planner="vortex",""
        }
    }
    if model=="" {model="vortex"}
    seconds:=a.ScheduleS
    if a.Nonstop || seconds<30 {seconds=30}
    result:=s.gw("POST","/agents",map[string]any{
        "id":a.ID,"name":a.Name,"model":model,"planner":planner,
        "system":a.SystemPrompt,"goal":a.Goal,"interval_s":seconds,
        "run_on":"cloudpc","on":a.Running,
        "permissions":a.Permissions,"allow_actions":a.AlwaysAllow,
    })
    if result["ok"]!=true {
        return fmt.Errorf("Cloud PC worker schedule was not accepted: %v",result["message"])
    }
    return nil
}
func (s *Server) cloudWorkerStatus() map[string]any {
    return s.gw("GET","/agents/worker/online",nil)
}

func agentRemoteMode(a store.Agent) string {
    mode:=strings.TrimSpace(a.RunOn)
    if mode=="" {return "local"}
    return mode
}
