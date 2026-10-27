package main

import (
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "strings"
    "testing"
    "time"
)

func testCloudWorkerSetup(t *testing.T) (*Key,*bgAgent) {
    t.Helper()
    agMu.Lock()
    oldAgents,oldBusy,oldFile,oldPresence:=agents,agBusy,agFile,workerPresence
    agents=map[string]*bgAgent{}
    agBusy=map[string]bool{}
    agFile=t.TempDir()+"/agents.json"
    workerPresence=map[string]agentWorkerPresence{}
    agMu.Unlock()
    mu.Lock()
    oldKeys:=keys
    k:=&Key{ID:"test-cloud-key",Scopes:[]string{"chat","cloudpc"},Models:[]string{"vortex"}}
    keys=[]*Key{k}
    mu.Unlock()
    t.Cleanup(func(){
        agMu.Lock()
        agents,agBusy,agFile,workerPresence=oldAgents,oldBusy,oldFile,oldPresence
        agMu.Unlock()
        mu.Lock();keys=oldKeys;mu.Unlock()
    })
    a:=&bgAgent{ID:"test-agent",KeyID:k.ID,Name:"Remote test",
        Model:"vortex",RunOn:"cloudpc",Goal:"Review a worktree",On:true,
        IntervalS:30,Permissions:[]string{"files-read"},Status:"queued"}
    agMu.Lock();agents[a.ID]=a;agMu.Unlock()
    return k,a
}
func testCloudWorkerRequest(k *Key,action string,body string)*httptest.ResponseRecorder{
    req:=httptest.NewRequest("POST","/v1/agents/worker/"+action,strings.NewReader(body))
    req.Header.Set("Content-Type","application/json")
    w:=httptest.NewRecorder()
    handleAgentWorker(w,req,k,action)
    return w
}
func TestCloudAgentWorkerLeaseAndStop(t *testing.T) {
    k,a:=testCloudWorkerSetup(t)
    if w:=testCloudWorkerRequest(k,"claim",`{"worker_id":"cloudpc-demo-123"}`);w.Code!=403 {
        t.Fatalf("claim without registered heartbeat was allowed: %d",w.Code)
    }
    w:=testCloudWorkerRequest(k,"heartbeat",`{"worker_id":"cloudpc-demo-123"}`)
    if w.Code!=200 {t.Fatal(w.Code,w.Body.String())}
    w=testCloudWorkerRequest(k,"claim",`{"worker_id":"cloudpc-demo-123"}`)
    if w.Code!=200 {t.Fatal(w.Code,w.Body.String())}
    var claim struct{Job struct{
        ID string `json:"id"`
        AgentID string `json:"agent_id"`
        Lease string `json:"lease"`
        Permissions []string `json:"permissions"`
    } `json:"job"` }
    if err:=json.Unmarshal(w.Body.Bytes(),&claim);err!=nil {t.Fatal(err)}
    if claim.Job.AgentID!=a.ID || len(claim.Job.Lease)!=43 ||
        len(claim.Job.Permissions)!=1 || claim.Job.Permissions[0]!="files-read" {
        t.Fatalf("bad remote claim: %#v",claim)
    }
    agMu.Lock()
    if strings.Contains(string(mustJSON(a)),"\\\"lease\\\":\\\""+claim.Job.Lease) || a.Pending.LeaseHash==claim.Job.Lease {
        agMu.Unlock();t.Fatal("plaintext worker lease persisted")
    }
    agMu.Unlock()
    makeRequest:=func(action,status,lease string)*httptest.ResponseRecorder{
        payload,_:=json.Marshal(map[string]any{
            "worker_id":"cloudpc-demo-123","agent_id":a.ID,"job_id":claim.Job.ID,
            "lease":lease,"status":status,"result":"Worker verified: reviewed files only",
        })
        return testCloudWorkerRequest(k,action,string(payload))
    }
    if w=makeRequest("report","done","incorrect");w.Code!=409 {
        t.Fatal("forged lease completed worker task",w.Code)
    }
    if w=makeRequest("status","",claim.Job.Lease);w.Code!=200 {t.Fatal(w.Code,w.Body.String())}
    if w=makeRequest("report","done",claim.Job.Lease);w.Code!=200 {t.Fatal(w.Code,w.Body.String())}
    if a.Runs!=1 || a.Pending!=nil || a.LastRun==0 || a.Status!="idle" {
        t.Fatalf("real worker report did not update agent: %#v",a)
    }
    if w=makeRequest("report","done",claim.Job.Lease);w.Code!=409 {t.Fatal("lease replay accepted",w.Code)}
    a.LastRun=0
    w=testCloudWorkerRequest(k,"claim",`{"worker_id":"cloudpc-demo-123"}`)
    var second struct{Job struct{ID,Lease string}}
    _=json.Unmarshal(w.Body.Bytes(),&second)
    if second.Job.ID=="" {t.Fatal("second task did not queue")}
    stop:=httptest.NewRecorder()
    req:=httptest.NewRequest(http.MethodPost,"/v1/agents/"+a.ID+"/toggle",strings.NewReader(`{"on":false}`))
    handleAgents(stop,req,k)
    if stop.Code!=200 {t.Fatal("agent could not stop",stop.Code,stop.Body.String())}
    if w=makeRequest("status","",claim.Job.Lease);w.Code!=409 {t.Fatal("stopped worker was not revoked",w.Code)}
}
func TestCloudAgentWorkerRespectsRevokedScopeAndOnlineTTL(t *testing.T) {
    k,a:=testCloudWorkerSetup(t)
    if !agAuthorized(a){t.Fatal("agent should be authorized with chat+model")}
    k.Models=[]string{"different-model"}
    if agAuthorized(a){t.Fatal("revoked model grant was ignored")}
    k.Models=[]string{"vortex"}
    k.Scopes=[]string{"cloudpc"}
    if agAuthorized(a){t.Fatal("missing chat scope was ignored")}
    k.Scopes=[]string{"chat","cloudpc"}
    k.Disabled=true
    if agAuthorized(a){t.Fatal("disabled key could run agent")}
    k.Disabled=false
    now:=time.Now()
    workerPresence[k.ID]=agentWorkerPresence{Name:"test",LastSeen:now.Add(-2*time.Minute).Unix()}
    if workerOnline(k.ID,now){t.Fatal("expired heartbeat counted as online")}
}
func mustJSON(a any) []byte {b,_:=json.Marshal(a);return b}
