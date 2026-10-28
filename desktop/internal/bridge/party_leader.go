package bridge

import (
    "encoding/json"
    "fmt"
    "strings"
    "time"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// The group's leader is a PLANNER and reviewer. It cannot alter members'
// persisted grants, change machine policy, or invent tool results.
type groupAssignment struct {
    Member string `json:"member"`
    Task string `json:"task"`
}
type groupPlan struct { Assignments []groupAssignment `json:"assignments"` }

func normalizeGroupLeader(leader string, members []string) string {
    if len(members)==0 {return ""}
    for _,member:=range members {if member==leader {return leader}}
    return members[0] // migrate old group chats without leaving them leaderless
}

func parseLeaderAssignments(response string, members []string, userText string) []groupAssignment {
    var plan groupPlan
    cleaned:=strings.TrimSpace(response)
    cleaned=strings.TrimPrefix(cleaned,"\x60\x60\x60json")
    cleaned=strings.TrimSuffix(cleaned,"\x60\x60\x60")
    if a:=strings.Index(cleaned,"{");a>=0 {
        if b:=strings.LastIndex(cleaned,"}");b>a {cleaned=cleaned[a:b+1]}
    }
    _=json.Unmarshal([]byte(cleaned),&plan)
    present:=map[string]bool{}
    result:=[]groupAssignment{}
    allowed:=map[string]bool{}
    for _,member:=range members {allowed[member]=true}
    for _,assignment:=range plan.Assignments {
        if !allowed[assignment.Member] || present[assignment.Member] {continue}
        text:=strings.TrimSpace(assignment.Task)
        if text=="" {continue}
        if len(text)>2000 {text=text[:2000]}
        result=append(result,groupAssignment{Member:assignment.Member,Task:text})
        present[assignment.Member]=true
    }
    if len(result)==0 {
        for _,member:=range members {
            result=append(result,groupAssignment{Member:member,Task:"Investigate this user request using your specific expertise; report actual evidence, limits and next steps: "+clipS(userText,900)})
        }
    }
    return result
}

func groupMemberList(c *store.Chat, leader string) []string {
    members:=[]string{}
    for _,id:=range c.Members {if id!=leader {members=append(members,id)}}
    return members
}
func groupUserText(c *store.Chat) string {
    for i:=len(c.Messages)-1;i>=0;i-- {if c.Messages[i].Role=="user" {return c.Messages[i].Content}}
    return ""
}
func isActionAssignment(t string) bool {
    t=strings.ToLower(strings.TrimSpace(t))
    for _,pre:=range []string{"how ","explain ","what is ","summarize ","discuss ","compare "} {
        if strings.HasPrefix(t,pre) {return false}
    }
    for _,word:=range []string{"download ","write ","edit ","create ","run ","open ","fix ","update ","make ","list files","read file","execute ","install ","check files","patch "} {
        if strings.Contains(t,word) {return true}
    }
    return false
}

// Wait only briefly for a delegated computer job: approval can outlive the
// chat request. A pending step is never called completed.
func waitGroupRun(id string, limit time.Duration) string {
    deadline:=time.Now().Add(limit)
    for time.Now().Before(deadline) {
        runs.mu.Lock()
        r:=runs.runs[id]
        status,result,pending:="missing","",false
        if r!=nil {status,result,pending=r.Status,r.Result,r.Pending!=nil}
        runs.mu.Unlock()
        if status=="done" || status=="error" || status=="stopped" {return status+": "+clipS(result,2000)}
        if pending {return "waiting for a user approval in Activity (run "+id+"); no action has been approved yet"}
        time.Sleep(400*time.Millisecond)
    }
    return "still running in Activity (run "+id+"); the group cannot claim completion yet"
}

func (s *Server) groupSendLed(c *store.Chat, comp store.Composer, local bool) map[string]any {
    leaderID:=normalizeGroupLeader(c.LeaderID,c.Members)
    if leaderID=="" {return map[string]any{"error":"Group has no members"}}
    userText:=groupUserText(c)
    members:=groupMemberList(c,leaderID)
    if len(members)==0 {return map[string]any{"error":"A led group needs at least one worker"}}
    leader:=s.memberFor(leaderID)
    leaderProviderID:=leaderID
    if strings.HasPrefix(leaderID,"model:") {leaderProviderID=""}
    maxTok,hint:=lengthParams(comp)
    if maxTok<350 {maxTok=350}
    ctx:=s.workspaceContext(c.ID,userText)
    if ctx!="" {hint+="\n"+ctx}
    names:=[]string{}
    for _,id:=range members {m:=s.memberFor(id);names=append(names,id+" = "+m.Name+" (model "+m.Model+")")}
    planSystem:="You are the designated leader for an agent team. Assign concrete subtasks to each available worker. " +
      "Respond ONLY as JSON: {\"assignments\":[{\"member\":\"EXACT_MEMBER_ID\",\"task\":\"specific task\"}]}. " +
      "Never invent access, grant new permissions, or ask a worker to exceed what the user actually authorized. " +
      "For software or research tasks divide work sensibly, and for computer tasks require tool-backed evidence. "+
      "Available team: "+strings.Join(names,", ")+"\n"+hint+"\n"+c.GroupInstructions
    plan,err:=s.complete(leaderProviderID,leader.Model,[]map[string]string{{"role":"system","content":planSystem},{"role":"user","content":userText}},maxTok)
    if err!=nil {return map[string]any{"error":"Leader could not prepare assignments: "+err.Error()}}
    assignments:=parseLeaderAssignments(plan,members,userText)
    replies:=[]map[string]string{}
    evidence:=[]string{}
    limit:=len(assignments)
    if limit>6 {limit=6} // bounded team, prevents unbounded consumption
    for _,a:=range assignments[:limit] {
        worker:=s.memberFor(a.Member)
        task:="Original user request: "+userText+"\nLeader assignment: "+a.Task+"\nOnly perform work covered by the user's request and your existing tool permissions."
        result:=""
        if a.Member==leaderID {continue}
        if !strings.HasPrefix(a.Member,"model:") && isActionAssignment(a.Task) {
            out:=s.startRunFrom(a.Member,task,"",local)
            if out["ok"]==true {
                if r,ok:=out["run"].(Run);ok {result=waitGroupRun(r.ID,45*time.Second)}
                if result=="" {result="Task submitted to Activity; result not yet confirmed."}
            }else {result="Blocked: "+fmt.Sprint(out["message"])}
        }else{
            prompt:=[]map[string]string{
                {"role":"system","content":"You are "+worker.Name+", worker in an agent team directed by "+leader.Name+". "+
                    "Answer only your assigned subtask with factual reasoning; do not claim any tool, browser or system action happened without results."},
                {"role":"user","content":task},
            }
            agentID:=a.Member
            if strings.HasPrefix(agentID,"model:") {agentID=""}
            r,e:=s.complete(agentID,worker.Model,prompt,maxTok)
            if e!=nil {result="Error: "+e.Error()} else {result=strings.TrimSpace(r)}
        }
        evidence=append(evidence,worker.Name+": "+clipS(result,3500))
        c.Messages=append(c.Messages,store.Msg{Role:"assistant",Name:worker.Name,Content:result})
        s.St.SaveChat(*c)
        replies=append(replies,map[string]string{"name":worker.Name,"content":result})
    }
    summaryPrompt:="You are the team's designated leader. Give the user a single clear report based ONLY on the workers' real outputs. "+
      "Distinguish completed verified work from running, waiting approval, and blocked tasks. "+
      "Never say an action happened based on mere proposals. Don't reveal private tokens or fabricate browser access.\n"+
      c.GroupInstructions
    summary,err:=s.complete(leaderProviderID,leader.Model,[]map[string]string{
        {"role":"system","content":summaryPrompt},
        {"role":"user","content":"Original request: "+userText+"\nWorker outcomes:\n"+strings.Join(evidence,"\n")},
    },maxTok)
    if err!=nil {summary="Team report (leader could not synthesize):\n"+strings.Join(evidence,"\n")}
    summary=strings.TrimSpace(summary)
    c.Messages=append(c.Messages,store.Msg{Role:"assistant",Name:leader.Name+" · leader",Content:summary})
    s.St.SaveChat(*c)
    replies=append(replies,map[string]string{"name":leader.Name+" · leader","content":summary})
    return map[string]any{"reply":summary,"replies":replies,"leader":leaderID,"workspace":c.WorkspaceID}
}
