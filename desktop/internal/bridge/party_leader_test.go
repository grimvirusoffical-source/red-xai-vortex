package bridge

import (
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "strings"
    "sync/atomic"
    "testing"
    "time"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func TestLeaderAssignmentsSkipUnknownMembersAndDuplicateAssignments(t *testing.T){
    members:=[]string{"model:coder","agent:writer"}
    raw:=`{"assignments":[{"member":"model:coder","task":"Review build"},{"member":"model:coder","task":"Do more"},{"member":"unknown","task":"Delete everything"}]}`
    got:=parseLeaderAssignments(raw,members,"Review project")
    if len(got)!=1 || got[0].Member!="model:coder" || got[0].Task!="Review build" {
        t.Fatalf("leader was allowed to add uninvited members: %#v",got)
    }
    if normalizeGroupLeader("outsider",members)!=members[0] {t.Fatal("old group leader not repaired")}
}
func TestLedGroupHasOneLeaderAndIsolatedProjectWorkspace(t *testing.T){
    var calls atomic.Int32
    gateway:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
        calls.Add(1)
        var request struct{ Messages []map[string]string `json:"messages"` }
        _=json.NewDecoder(r.Body).Decode(&request)
        text:="Worker completed an analysis; no computer action taken"
        system:=""
        if len(request.Messages)>0 {system=request.Messages[0]["content"]}
        if strings.Contains(system,"designated leader for an agent team") {
            text=`{"assignments":[{"member":"model:coder","task":"Review the unit tests"}]}`
        } else if strings.Contains(system,"team's designated leader"){
            text="Team review: worker analyzed tests, but no files were changed."
        }
        w.Header().Set("Content-Type","application/json")
        _=json.NewEncoder(w).Encode(map[string]any{"choices":[]any{map[string]any{"message":map[string]string{"content":text}}}})
    }))
    defer gateway.Close()
    s:=workspaceServer(t)
    st:=s.St.Settings
    st.BaseURL=gateway.URL+"/v1"
    st.PlainChat=true
    s.St.SetSettings(st)
    newGroup:=s.partyNewWithLeader("Team review",[]string{"vortex-default","model:coder"},"vortex-default","Review project","Avoid file changes")
    if newGroup["ok"]!=true {t.Fatalf("group create failed: %v",newGroup)}
    id:=newGroup["id"].(string)
    w:=s.St.WorkspaceSnapshot()
    if len(w.Projects)!=1 || len(w.ChatSettings)!=1 || w.ChatSettings[0].ChatID!=id ||
        w.ChatSettings[0].ProjectID!=w.Projects[0].ID || w.Projects[0].MemoryEnabled {
        t.Fatalf("project separation missing: %#v",w)
    }
    var c *store.Chat
    for i:=range s.St.Chats {if s.St.Chats[i].ID==id{c=&s.St.Chats[i];break}}
    if c==nil {t.Fatal("group chat not persisted")}
    c.Messages=append(c.Messages,store.Msg{Role:"user",Content:"Please review this project"})
    result:=s.groupSendLed(c,store.Composer{Length:"short"},true)
    replies,ok:=result["replies"].([]map[string]string)
    if !ok || len(replies)!=2 || calls.Load()!=3 {t.Fatalf("leader did not coordinate two stages: %#v (%d requests)",result,calls.Load())}
    if !strings.Contains(result["reply"].(string),"no files were changed") {t.Fatal("leader claimed unverified computer action")}
    if result["workspace"]!=w.Projects[0].ID {t.Fatal("group did not retain workspace identity")}
}
func TestAgentDueRequiresEnabledScheduling(t *testing.T) {
    if agentDue(store.Agent{Running:false,ScheduleS:15,Goal:"check"},time.Now()) {
        t.Fatal("disabled recurring agent started")
    }
}
