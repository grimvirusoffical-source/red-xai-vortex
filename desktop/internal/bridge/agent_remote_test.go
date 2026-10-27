package bridge

import (
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "strings"
    "testing"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func cloudAgentMockGateway(t *testing.T, onChange func(path string, payload map[string]any) (int,map[string]any)) *httptest.Server {
    t.Helper()
    return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
        w.Header().Set("Content-Type","application/json")
        if r.URL.Path=="/v1/models"{
            _=json.NewEncoder(w).Encode(map[string]any{"data":[]map[string]string{
                {"id":"vortex"},{"id":"qwen2.5-coder-14b"},{"id":"r1-distill-qwen-14b"},
            }})
            return
        }
        if r.URL.Path=="/v1/agents/worker/online"{
            _=json.NewEncoder(w).Encode(map[string]any{"online":true})
            return
        }
        payload:=map[string]any{}
        _=json.NewDecoder(r.Body).Decode(&payload)
        status,response:=onChange(r.URL.Path,payload)
        w.WriteHeader(status)
        _=json.NewEncoder(w).Encode(response)
    }))
}
func TestCloudAgentSyncUsesAuthorizedSpecialistsAndExactExecutionGrants(t *testing.T){
    called:=false
    gw:=cloudAgentMockGateway(t,func(path string,payload map[string]any)(int,map[string]any){
        if path!="/v1/agents" {t.Errorf("wrong path: %s",path)}
        called=true
        if payload["run_on"]!="cloudpc" || payload["model"]!="qwen2.5-coder-14b" ||
           payload["planner"]!="r1-distill-qwen-14b" || payload["allow_actions"]!=true {
            t.Errorf("wrong remote worker policy: %v",payload)
        }
        grants,ok:=payload["permissions"].([]any)
        if !ok || len(grants)!=2 || grants[0]!="files-read" || grants[1]!="shell" {
            t.Errorf("unexpected grants: %#v",grants)
        }
        return 200,map[string]any{"id":payload["id"]}
    })
    defer gw.Close()
    s:=workspaceServer(t)
    settings:=s.St.Settings
    settings.BaseURL=gw.URL+"/v1"
    settings.PlainChat=true
    s.St.SetSettings(settings)
    agent:=store.Agent{ID:"remote-test",Name:"Code reviewer",Provider:"vortex",Model:"vortex",
       ModelMode:"mix",Goal:"Debug code and tests",RunOn:"cloudpc",ScheduleS:60,Running:true,
       PCControlOn:true,AlwaysAllow:true,Permissions:[]string{"files-read","shell"}}
    if err:=s.syncCloudAgent(agent);err!=nil {t.Fatal(err)}
    if !called {t.Fatal("Cloud PC agent configuration was not sent to the gateway")}
    if status:=s.cloudWorkerStatus();status["ok"]!=true || status["online"]!=true {
        t.Fatalf("online worker not detected: %v",status)
    }
}
func TestCloudAgentOfflineCannotBeMarkedRunningLocally(t *testing.T){
    gw:=cloudAgentMockGateway(t,func(path string,payload map[string]any)(int,map[string]any){
        return 409,map[string]any{"error":"Cloud PC worker is offline"}
    })
    defer gw.Close()
    s:=workspaceServer(t)
    settings:=s.St.Settings
    settings.BaseURL=gw.URL+"/v1"
    settings.PlainChat=true
    s.St.SetSettings(settings)
    result:=s.saveUnifiedAgent(map[string]any{
        "name":"Remote trial","provider":"vortex","model":"vortex","modelMode":"single",
        "goal":"Read this remote workspace", "scheduleSeconds":float64(60),
        "running":true,"runOn":"cloudpc", "permissions":[]any{"files-read"},
        "pcControlOn":false,
    })
    if result["ok"]==true || !strings.Contains(result["message"].(string),"offline") {
        t.Fatalf("offline task advertised as running: %v",result)
    }
    for _,a:=range s.St.Agents {
        if a.Name=="Remote trial" {t.Fatal("failed remote schedule was persisted as active")}
    }
}
func TestRemoteTaskPauseAndKillRevokeWorkerThroughGateway(t *testing.T) {
    toggles:=[]bool{}
    gw:=cloudAgentMockGateway(t,func(path string,payload map[string]any)(int,map[string]any){
        if strings.HasSuffix(path,"/toggle"){
            toggles=append(toggles,payload["on"]==true)
        }
        return 200,map[string]any{"on":payload["on"]}
    })
    defer gw.Close()
    s:=workspaceServer(t)
    settings:=s.St.Settings
    settings.BaseURL=gw.URL+"/v1"
    settings.PlainChat=true
    s.St.SetSettings(settings)
    a:=store.Agent{ID:"remote-pause",Name:"Remote worker",Provider:"vortex",Model:"vortex",
        Goal:"Research",RunOn:"cloudpc",ScheduleS:60,Running:true}
    s.St.SaveAgent(a)
    if status:=s.agentToggle(map[string]any{"id":a.ID,"running":false});status["ok"]!=true {
        t.Fatalf("Could not revoke remote agent: %v",status)
    }
    a.Running=true
    s.St.SaveAgent(a)
    result:=s.agentKillAll(nil)
    if result["ok"]!=true {t.Fatalf("Emergency stop failed: %v",result)}
    if len(toggles)!=2 || toggles[0] || toggles[1] {
        t.Fatalf("Remote lease/schedule was not revoked on Pause and Stop: %v",toggles)
    }
    for _,current:=range s.St.Agents {
        if current.ID==a.ID && current.Running {t.Fatal("Remote agent remained locally active after emergency stop")}
    }
}
