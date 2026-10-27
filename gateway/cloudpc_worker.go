package main

// Authenticated worker queue for opted-in remote agent execution.
//
// A worker uses the same scoped Vortex API key as its owner, running in the
// user's independently authorized Cloud PC. The gateway does NOT run GUI
// actions or pretend that the language model has access to a remote desktop.
// Lease tokens stay out of logs and persisted state (only hashes are saved).
// The worker must also independently enforce its own OS permissions.

import (
    "crypto/sha256"
    "crypto/subtle"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "net/http"
    "sort"
    "strings"
    "time"
)

const (
    workerPresenceTTL = 70 * time.Second
    workerLeaseTTL = 8 * time.Minute
)
type agentWorkerJob struct {
    ID string `json:"id"`
    WorkerID string `json:"worker_id"`
    LeaseHash string `json:"lease_hash"`
    LeasedUntil int64 `json:"leased_until"`
    Started int64 `json:"started"`
}
type agentWorkerPresence struct {
    Name string `json:"name"`
    LastSeen int64 `json:"last_seen"`
}
var workerPresence = map[string]agentWorkerPresence{} // API Key ID -> last heartbeat (memory only)

func workerOnline(keyID string, now time.Time) bool {
    p, found := workerPresence[keyID]
    return found && now.Sub(time.Unix(p.LastSeen,0)) < workerPresenceTTL
}
func workerTokenHash(token string) string {
    sum := sha256.Sum256([]byte(token))
    return hex.EncodeToString(sum[:])
}
func validWorkerLease(job *agentWorkerJob, id, secret string, now time.Time) bool {
    if job == nil || job.WorkerID != id || len(secret) != 43 ||
        job.LeasedUntil < now.Unix() { return false }
    actual, err := hex.DecodeString(job.LeaseHash)
    if err != nil || len(actual) != sha256.Size {return false}
    expected := sha256.Sum256([]byte(secret))
    return subtle.ConstantTimeCompare(actual,expected[:])==1
}
func agentWorkerDue(a *bgAgent, now time.Time) bool {
    if a == nil || !a.On || a.RunOn != "cloudpc" || a.Goal == "" {return false}
    interval:=a.IntervalS
    if interval<30 {interval=30}
    return a.LastRun==0 || now.Unix()-a.LastRun>=int64(interval)
}
func canRemoteWorker(k *Key) bool {
    return hasScope(k,"chat") && canCloudPC(k)
}
func remoteWorkerPermissions(a *bgAgent) []string {
    allowed:=map[string]bool{"web":true,"files-read":true,"files-write":true,"shell":true,"browser":true}
    out:=[]string{}
    for _,item:=range a.Permissions {
        if allowed[item] {out=append(out,item)}
    }
    return out
}
func workerClaimLocked(k *Key, name string, now time.Time) map[string]any {
    names:=[]string{}
    for id,a:=range agents {
        if a.KeyID==k.ID && agentWorkerDue(a,now) {names=append(names,id)}
    }
    sort.Strings(names)
    for _,id:=range names {
        a:=agents[id]
        if a.Pending!=nil {
            if a.Pending.LeasedUntil>now.Unix() {continue}
            a.Pending=nil
            agBusy[id]=false
        }
        if agBusy[id] || !agAuthorized(a) {continue}
        token:=randB62(43)
        jobID:="aj_"+randB62(18)
        a.Pending=&agentWorkerJob{ID:jobID,WorkerID:name,LeaseHash:workerTokenHash(token),
            LeasedUntil:now.Add(workerLeaseTTL).Unix(),Started:now.Unix()}
        agBusy[id]=true
        a.Status="running"
        agSaveLocked()
        h:=a.History
        if len(h)>12 {h=h[len(h)-12:]}
        return map[string]any{"ok":true,"job":map[string]any{
            "id":jobID,"agent_id":id,"model":a.Model,"system":a.System,"goal":a.Goal,
            "permissions":remoteWorkerPermissions(a),"allow_actions":a.AlwaysAllow,
            "history":h,"lease":token,"deadline":a.Pending.LeasedUntil,
        }}
    }
    return map[string]any{"ok":true,"job":nil}
}
func workerReportLocked(a *bgAgent, status, result string, now time.Time) {
    a.Pending=nil
    agBusy[a.ID]=false
    a.Runs++
    a.LastRun=now.Unix()
    if len(result)>6000 {result=result[:6000]+"\n[truncated]"}
    if status=="done" {
        a.Status="idle"
        a.LastError=""
        agAppend(a,agentTurn{"user","[Cloud PC worker task] "+a.Goal,now.Unix(),true},
            agentTurn{"assistant",result,now.Unix(),true})
        a.Unread++
        if strings.TrimSpace(result)=="DONE" {a.On=false;a.Status="done"}
    } else {
        a.LastError="Cloud PC worker "+status+": "+result
        a.Status="error"
    }
    notify(a.KeyID,"agent","Cloud PC worker "+status+": "+a.Name,result,a.ID)
    agSaveLocked()
}
func handleAgentWorker(w http.ResponseWriter, r *http.Request, k *Key, action string) {
    w.Header().Set("Content-Type","application/json")
    w.Header().Set("Cache-Control","no-store")
    fail:=func(status int,message string){w.WriteHeader(status);_ = json.NewEncoder(w).Encode(map[string]any{"error":message})}
    if !canRemoteWorker(k) {fail(http.StatusForbidden,"Cloud PC and chat scopes are required for worker access");return}
    if r.Method!=http.MethodPost && !(action=="online"&&r.Method==http.MethodGet) {
        fail(http.StatusMethodNotAllowed,"unsupported method");return
    }
    var in struct {
        WorkerID string `json:"worker_id"`
        AgentID string `json:"agent_id"`
        JobID string `json:"job_id"`
        Lease string `json:"lease"`
        Status string `json:"status"`
        Result string `json:"result"`
    }
    if r.Method==http.MethodPost {
        if err:=json.NewDecoder(http.MaxBytesReader(w,r.Body,64<<10)).Decode(&in);err!=nil{
            fail(http.StatusBadRequest,"invalid worker request");return
        }
    }
    now:=time.Now()
    agMu.Lock()
    defer agMu.Unlock()
    switch action {
    case "heartbeat":
        if len(in.WorkerID)<6 || len(in.WorkerID)>80 {
            fail(400,"worker_id must identify the user-configured worker");return
        }
        workerPresence[k.ID]=agentWorkerPresence{Name:in.WorkerID,LastSeen:now.Unix()}
        _=json.NewEncoder(w).Encode(map[string]any{"ok":true,"online":true})
    case "online":
        _=json.NewEncoder(w).Encode(map[string]any{"ok":true,"online":workerOnline(k.ID,now)})
    case "claim":
        if len(in.WorkerID)<6 || len(in.WorkerID)>80 || !workerOnline(k.ID,now) ||
            workerPresence[k.ID].Name!=in.WorkerID {fail(403,"worker must register a heartbeat before claiming tasks");return}
        _=json.NewEncoder(w).Encode(workerClaimLocked(k,in.WorkerID,now))
    case "status","report":
        a:=agents[in.AgentID]
        if a==nil || a.KeyID!=k.ID {fail(404,"unknown agent");return}
        if !validWorkerLease(a.Pending,in.WorkerID,in.Lease,now) ||
            a.Pending.ID!=in.JobID {fail(409,"lease expired, replaced or revoked; cancel this task");return}
        if !a.On || a.RunOn!="cloudpc" || !agAuthorized(a) {
            fail(409,"agent stopped or permissions revoked; cancel this task");return
        }
        if action=="status" {
            _=json.NewEncoder(w).Encode(map[string]any{"ok":true,"continue":true})
            return
        }
        if in.Status!="done" && in.Status!="error" && in.Status!="stopped" {
            fail(400,"status must be done, error, or stopped");return
        }
        workerReportLocked(a,in.Status,in.Result,now)
        _=json.NewEncoder(w).Encode(map[string]any{"ok":true,"reported":true})
    default:
        fail(404,fmt.Sprintf("unknown worker action %s",action))
    }
}
