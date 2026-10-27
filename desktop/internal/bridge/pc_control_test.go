package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func pcRequest(t *testing.T, s *Server, method string, in map[string]any, phone bool) *httptest.ResponseRecorder {
	t.Helper()
	data, _ := json.Marshal(in)
	r := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:1234/bridge/"+method, strings.NewReader(string(data)))
	r.RemoteAddr = "127.0.0.1:50000"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "http://127.0.0.1:1234")
	if phone {
		r = r.WithContext(context.WithValue(r.Context(), workspacePhoneSessionKey{}, true))
	}
	w := httptest.NewRecorder()
	s.handle(w, r)
	return w
}
func TestPCPolicyLocalOnlyAndStaleSetCannotUndoStop(t *testing.T) {
	s := workspaceServer(t)
	if w := pcRequest(t, s, "pcControl.set", map[string]any{"alwaysAllow": true, "revision": 0}, true); w.Code != 403 {
		t.Fatal("phone enabled full control", w.Code)
	}
	if w := pcRequest(t, s, "pcControl.set", map[string]any{"alwaysAllow": true, "revision": 0}, false); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if s.pcStatus(true)["alwaysAllow"] != true {
		t.Fatal("local opt in failed")
	}
	if w := pcRequest(t, s, "pcControl.stop", map[string]any{}, true); w.Code != 200 {
		t.Fatal("authenticated phone cannot stop", w.Code)
	}
	if s.pcStatus(true)["alwaysAllow"] != false {
		t.Fatal("stop retained automatic mode")
	}
	if w := pcRequest(t, s, "pcControl.set", map[string]any{"alwaysAllow": true, "revision": 1}, false); w.Code != 409 {
		t.Fatal("queued enable after stop allowed", w.Code)
	}
	r := httptest.NewRequest("POST", "http://127.0.0.1:1234/bridge/pcControl.set", strings.NewReader(`{"alwaysAllow":true,"revision":2}`))
	r.RemoteAddr = "127.0.0.1:1"
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "https://attacker.invalid")
	w := httptest.NewRecorder()
	s.handle(w, r)
	if w.Code != 403 {
		t.Fatal("cross-site policy change allowed")
	}
	s.St.SetSettings(s.St.Settings)
	if s.pcStatus(true)["alwaysAllow"] != false {
		t.Fatal("general settings enabled full control")
	}
}
func TestPCKillInvalidatesBufferedApprovalAndAutomaticAction(t *testing.T) {
	s := workspaceServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	approval := &Approval{ID: "fixture", decided: make(chan bool, 1)}
	approval.decided <- true
	r := &Run{ID: workspaceID("pc-test"), Status: "waiting", Started: time.Now(), Pending: approval, cancel: cancel, localOperator: true}
	s.registerPCRun(r)
	if err := s.St.SetPCPolicy(true); err != nil {
		t.Fatal(err)
	}
	if !s.autoApprove(ctx, r) {
		t.Fatal("local explicit mode did not allow action")
	}
	count, err := s.stopPCControl()
	if err != nil || count != 1 {
		t.Fatal(count, err)
	}
	called := false
	err = pcGuard(context.WithValue(ctx, pcExecutionKey{}, pcExecution{server: s, run: r, auto: true}), func() error { called = true; return nil })
	if err == nil || called {
		t.Fatal("queued action executed after kill")
	}
	if s.approve(r.ID, true)["ok"] != false {
		t.Fatal("killed approval revived")
	}
	if r.Pending != nil || r.Status != "stopped" || ctx.Err() == nil {
		t.Fatal("kill did not clear pending/cancel")
	}
}
func TestPCManualModeRemoteRunsAndPolicyChangeRecheck(t *testing.T) {
	s := workspaceServer(t)
	ctx := context.Background()
	r := &Run{ID: workspaceID("pc-test"), Status: "running", localOperator: true}
	s.registerPCRun(r)
	if s.autoApprove(ctx, r) {
		t.Fatal("default skipped approval")
	}
	s.St.SetPCPolicy(true)
	r.localOperator = false
	if s.autoApprove(ctx, r) {
		t.Fatal("remote run inherited automatic policy")
	}
	r.localOperator = true
	if !s.autoApprove(ctx, r) {
		t.Fatal("local run missed opt in")
	}
	s.St.SetPCPolicy(false)
	called := false
	err := pcGuard(context.WithValue(ctx, pcExecutionKey{}, pcExecution{server: s, run: r, auto: true}), func() error { called = true; return nil })
	if err == nil || called {
		t.Fatal("mode change did not stop queued automatic action")
	}
	if s.autoApprove(ctx, r) {
		t.Fatal("manual mode skipped approval")
	}
}
func TestPCStopCancelsCommandDescendants(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix shell fixture; Windows cross-build checks taskkill tree fallback")
	}
	s := workspaceServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := &Run{ID: workspaceID("pc-test"), Status: "running", cancel: cancel}
	s.registerPCRun(r)
	dir := t.TempDir()
	marker := filepath.Join(dir, "late.txt")
	ready := filepath.Join(dir, "ready.txt")
	command := fmt.Sprintf("(sleep 1; printf late > '%s') & printf ready > '%s'; wait", marker, ready)
	result := make(chan error, 1)
	go func() {
		_, err := runPCCommand(context.WithValue(ctx, pcExecutionKey{}, pcExecution{server: s, run: r}), command, dir)
		result <- err
	}()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := os.Stat(ready); err != nil {
		t.Fatal("fixture never started")
	}
	s.stopPCControl()
	select {
	case <-result:
	case <-time.After(3 * time.Second):
		t.Fatal("command did not terminate")
	}
	time.Sleep(1100 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("background descendant survived kill")
	}
}
func TestPCLoopAutomaticAndManualFlows(t *testing.T) {
	for _, automatic := range []bool{false, true} {
		t.Run(fmt.Sprint(automatic), func(t *testing.T) {
			calls := 0
			model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				out := "finished"
				if calls == 1 {
					out = `<tool_call>{"name":"fixture_write","arguments":{}}</tool_call>`
				}
				json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": out}}}})
			}))
			defer model.Close()
			s := workspaceServer(t)
			t.Setenv("VORTEX_SECRETS_DIR", t.TempDir())
			s.St.Settings.BaseURL = model.URL
			s.St.Settings.PlainChat = true
			if err := s.St.SetPCPolicy(automatic); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			run := &Run{ID: workspaceID("pc-loop"), Status: "running", Started: time.Now(), cancel: cancel, localOperator: true}
			s.registerPCRun(run)
			executed := make(chan struct{}, 1)
			done := make(chan struct{})
			go func() {
				s.loop(ctx, run, member{Name: "Fixture", Model: "fixture"}, []tool{{name: "fixture_write", write: true, run: func(ctx context.Context, _ map[string]any) (string, error) {
					return "done", pcGuard(ctx, func() error { executed <- struct{}{}; return nil })
				}}})
				close(done)
			}()
			if !automatic {
				deadline := time.Now().Add(3 * time.Second)
				pending := false
				for time.Now().Before(deadline) {
					runs.mu.Lock()
					pending = run.Pending != nil
					runs.mu.Unlock()
					if pending {
						break
					}
					time.Sleep(10 * time.Millisecond)
				}
				if !pending {
					t.Fatal("manual mode did not ask")
				}
				select {
				case <-executed:
					t.Fatal("executed before approval")
				default:
				}
				if s.approve(run.ID, true)["ok"] != true {
					t.Fatal("approval failed")
				}
			}
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("run did not finish")
			}
			select {
			case <-executed:
			default:
				t.Fatal("approved action missing")
			}
		})
	}
}

func TestPCCompletedCommandPreservesRequestedBackgroundWork(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix shell compatibility fixture")
	}
	dir := t.TempDir()
	marker := filepath.Join(dir, "completed.txt")
	command := fmt.Sprintf("(sleep 0.1; printf done > '%s') >/dev/null 2>&1 & printf started", marker)
	output, err := runPCCommand(context.Background(), command, dir)
	if err != nil || output != "started" {
		t.Fatal(output, err)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if data, e := os.ReadFile(marker); e == nil && string(data) == "done" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("successful command unexpectedly killed its background work")
}
func TestPCStopRejectsRequestRegisteredAfterItsEpoch(t *testing.T) {
	s := workspaceServer(t)
	epoch := s.pcCurrentEpoch()
	s.stopPCControl()
	run := &Run{ID: workspaceID("pc-stale"), Status: "running"}
	if s.registerPCRunAt(run, epoch) {
		t.Fatal("request queued before stop registered afterward")
	}
}
func TestPatchAlwaysAllowRequiresTrustedLocalOrigin(t *testing.T) {
	for _, local := range []bool{false, true} {
		t.Run(fmt.Sprint(local), func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "main.txt")
			os.WriteFile(path, []byte("before\n"), 0600)
			s := workspaceServer(t)
			mustWorkspaceUpdate(t, s, func(w *store.Workspace) {
				w.ChatSettings = []store.ChatSettings{{ChatID: "chat", Coding: store.CodingContext{RepoPath: root}}}
			})
			if err := s.St.SetPCPolicy(true); err != nil {
				t.Fatal(err)
			}
			patch := "diff --git a/main.txt b/main.txt\n--- a/main.txt\n+++ b/main.txt\n@@ -1 +1 @@\n-before\n+after\n"
			result := s.workspacePatchAction(map[string]any{"action": "coding.patch.apply", "chatID": "chat", "patch": patch, "__localOperator": local})
			if result["ok"] != true {
				t.Fatal(result)
			}
			id := result["runID"].(string)
			if !local {
				runs.mu.Lock()
				pending := runs.runs[id].Pending != nil
				runs.mu.Unlock()
				if !pending {
					t.Fatal("remote patch inherited local automatic policy")
				}
				s.stopPCControl()
				if s.approve(id, true)["ok"] != false {
					t.Fatal("killed patch approval revived")
				}
				time.Sleep(30 * time.Millisecond)
				data, _ := os.ReadFile(path)
				if string(data) != "before\n" {
					t.Fatal("cancelled patch changed files")
				}
				return
			}
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				runs.mu.Lock()
				status := runs.runs[id].Status
				runs.mu.Unlock()
				if status == "done" {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			data, _ := os.ReadFile(path)
			if strings.ReplaceAll(string(data), "\r\n", "\n") != "after\n" {
				runs.mu.Lock()
				completed := runs.runs[id]
				state, result := completed.Status, completed.Result
				runs.mu.Unlock()
				t.Fatalf("local patch was not applied: run=%s result=%s", state, result)
			}
		})
	}
}
