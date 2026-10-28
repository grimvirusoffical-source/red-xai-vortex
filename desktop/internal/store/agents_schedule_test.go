package store

import (
    "testing"
    "time"
)

func TestAgentScheduleClaimIsAtomicAndNeverRestartsDisabledAgent(t *testing.T) {
    st:=OpenAt(t.TempDir())
    now:=time.Now().UTC().Truncate(time.Second)
    a:=Agent{ID:"schedule-test",Name:"Scheduled agent",Goal:"Review code",
        Running:true,ScheduleS:60,Permissions:[]string{"files-read"}}
    st.SaveAgent(a)
    due:=func(x Agent)bool {return x.Running && x.ScheduleS>0 && (x.LastRun.IsZero() || !now.Before(x.LastRun.Add(time.Duration(x.ScheduleS)*time.Second)))}
    first,ok:=st.ClaimAgentDue(a.ID,now,due)
    if !ok || first.LastRun!=now {t.Fatal("first due claim failed")}
    if _,ok:=st.ClaimAgentDue(a.ID,now,due);ok {t.Fatal("same periodic run was claimed twice")}
    first.Running=false
    st.SaveAgent(first)
    if _,ok:=st.ClaimAgentDue(a.ID,now.Add(time.Hour),due);ok {
        t.Fatal("disabled agent was scheduled after a concurrent edit")
    }
    snapshot:=st.AgentsSnapshot()
    for i:=range snapshot {
        if snapshot[i].ID==a.ID {snapshot[i].Permissions[0]="shell"}
    }
    var saved Agent
    for _,current:=range st.AgentsSnapshot() {if current.ID==a.ID {saved=current}}
    if len(saved.Permissions)!=1 || saved.Permissions[0]!="files-read" {
        t.Fatal("scheduler snapshot changed stored permissions")
    }
}
