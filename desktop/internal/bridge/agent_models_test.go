package bridge

import (
    "strings"
    "testing"
    "time"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func TestGenreRouterOnlyChoosesAuthorizedAvailableModels(t *testing.T) {
    a:=store.Agent{Provider:"vortex",Model:"vortex",ModelMode:"auto"}
    models:=[]string{"vortex","qwen2.5-coder-14b","r1-distill-qwen-14b"}
    if got,_:=availableAgentModels(a,"Debug my JavaScript source",models);got!="qwen2.5-coder-14b"{
        t.Fatalf("coding specialist got %q",got)
    }
    if got,_:=availableAgentModels(a,"Analyze this tricky proof",models);got!="r1-distill-qwen-14b"{
        t.Fatalf("reasoning specialist got %q",got)
    }
    a.ModelPool=[]string{"vortex"}
    if got,_:=availableAgentModels(a,"Debug JavaScript",models);got!="vortex"{
        t.Fatalf("pool restriction ignored: %q",got)
    }
    a.ModelPool=[]string{"unauthorized-secret-model"}
    if got,_:=availableAgentModels(a,"Debug JavaScript",models);got=="unauthorized-secret-model"{
        t.Fatal("router used a model absent from authenticated gateway listing")
    }
}
func TestMultiModelPlannerOnlyRunsWithSecondAuthorizedModel(t *testing.T) {
    a:=store.Agent{Provider:"vortex",Model:"vortex",ModelMode:"mix"}
    executive,plan:=availableAgentModels(a,"Fix this TypeScript function",[]string{"qwen2.5-coder-14b","r1-distill-qwen-14b","vortex"})
    if executive!="qwen2.5-coder-14b" || plan!="r1-distill-qwen-14b"{
        t.Fatalf("wrong pair %s %s",executive,plan)
    }
    a.Provider="openai"
    a.Model="gpt-test"
    exec,planner:=availableAgentModels(a,"Fix this TypeScript function",[]string{"vortex"})
    if exec!="gpt-test"||planner!=""{t.Fatalf("external key leaked into router: %s %s",exec,planner)}
}
func TestAgentPermissionsAndSchedule(t *testing.T){
    a:=store.Agent{ToolsOn:true,PCControlOn:true,Permissions:[]string{"web","files-read"},ScheduleS:15,Nonstop:true,Goal:"Check updates",Running:true}
    ts:=agentRunTools(a)
    if len(ts)!=3 {t.Fatalf("read-only agent got %d tools: %+v",len(ts),ts)}
    for _,tool:=range ts {if tool.write {t.Fatalf("write tool granted: %s",tool.name)}}
    now:=time.Now()
    if !agentDue(a,now){t.Fatal("new enabled agent never scheduled")}
    a.LastRun=now
    if agentDue(a,now.Add(14*time.Second)){t.Fatal("nonstop interval ignored")}
    if !agentDue(a,now.Add(16*time.Second)){t.Fatal("nonstop agent was not resumed")}
    a.Running=false
    if agentDue(a,now.Add(time.Hour)){t.Fatal("disabled agent still scheduled")}
    a.Permissions=[]string{}
    if got:=agentRunTools(a);len(got)!=0{t.Fatal("explicitly empty permission list got tools")}
}
func TestBrowserWorkNotMisrepresentedAsSimpleSearch(t *testing.T){
    goal:="In the background on Chrome find the Discord tab, check replies and send a message"
    if !requiresDesktopBrowser(goal){t.Fatal("GUI task was not recognized")}
    if requiresDesktopBrowser("Read a page of Go language documentation"){t.Fatal("non-GUI research was blocked")}
    if !strings.Contains(toolPrompt(nil),"TOOL_RESULT"){t.Fatal("agent tool protocol lost observation rules")}
}
