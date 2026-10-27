package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type pcExecutionKey struct{}
type pcExecution struct {
	server *Server
	run    *Run
	auto   bool
}

func pcLocalOperator(r *http.Request) bool {
	phone, _ := r.Context().Value(workspacePhoneSessionKey{}).(bool)
	if phone || !workspaceRequestAllowed(r) {
		return false
	}
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(peer)
	return ip != nil && ip.IsLoopback()
}
func (s *Server) pcStatus(local bool) map[string]any {
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	policy, err := s.St.PCPolicy()
	enabled := err == nil && policy.AlwaysAllow && !s.pcForceAsk
	active := 0
	runs.mu.Lock()
	for _, r := range runs.runs {
		if r.server == s && r.pcRun && r.Ended.IsZero() {
			active++
		}
	}
	runs.mu.Unlock()
	mode := "ask"
	if enabled {
		mode = "alwaysAllow"
	}
	out := map[string]any{"ok": true, "alwaysAllow": enabled, "canConfigure": local, "mode": mode, "activeRuns": active, "revision": s.pcRevision}
	if err != nil {
		out["message"] = err.Error()
	}
	return out
}
func pcError(w http.ResponseWriter, code int, message string) {
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "message": message})
}
func (s *Server) handlePCControl(w http.ResponseWriter, r *http.Request, method string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if !workspaceRequestAllowed(r) {
		pcError(w, 403, "same-origin JSON POST required")
		return
	}
	local := pcLocalOperator(r)
	if method == "pcControl.set" && !local {
		pcError(w, 403, "PC control mode can only be changed on this computer")
		return
	}
	var in map[string]any
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	var extra any
	if dec.Decode(&in) != nil || in == nil || dec.Decode(&extra) != io.EOF {
		pcError(w, 400, "invalid JSON object")
		return
	}
	switch method {
	case "pcControl.status":
	case "pcControl.set":
		enabled, ok := in["alwaysAllow"].(bool)
		if !ok {
			pcError(w, 400, "alwaysAllow must be true or false")
			return
		}
		s.pcMu.Lock()
		revision, ok := in["revision"].(float64)
		if !ok || revision < 0 || revision != float64(s.pcRevision) {
			s.pcMu.Unlock()
			pcError(w, 409, "PC control changed; refresh its status before changing mode")
			return
		}
		err := s.St.SetPCPolicy(enabled)
		if err == nil {
			s.pcForceAsk = false
			s.pcRevision++
		}
		s.pcMu.Unlock()
		if err != nil {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "message": err.Error()})
			return
		}
	case "pcControl.stop":
		count, err := s.stopPCControl()
		out := s.pcStatus(local)
		out["stopped"] = count
		if err != nil {
			out["message"] = "Stopped. Could not save manual mode: " + err.Error()
		}
		json.NewEncoder(w).Encode(out)
		return
	default:
		pcError(w, 404, "unknown PC control method")
		return
	}
	json.NewEncoder(w).Encode(s.pcStatus(local))
}
func (s *Server) stopPCControl() (int, error) {
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	s.pcEpoch++
	s.pcRevision++
	s.pcForceAsk = true
	err := s.St.RevokePCPolicy()
	stopped := 0
	runs.mu.Lock()
	defer runs.mu.Unlock()
	for _, r := range runs.runs {
		if r.server != s || !r.pcRun || !r.Ended.IsZero() {
			continue
		}
		if r.cancel != nil {
			r.cancel()
		}
		r.Status = "stopped"
		r.Result = "PC control stopped by you."
		r.Pending = nil
		r.Ended = time.Now()
		stopped++
	}
	return stopped, err
}
func (s *Server) registerPCRun(r *Run) {
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	s.addPCRunLocked(r)
}
func (s *Server) addPCRunLocked(r *Run) {
	r.server = s
	r.pcRun = true
	r.pcEpoch = s.pcEpoch
	runs.mu.Lock()
	runs.runs[r.ID] = r
	runs.mu.Unlock()
}
func (s *Server) pcCurrentEpoch() uint64 { s.pcMu.Lock(); defer s.pcMu.Unlock(); return s.pcEpoch }
func (s *Server) registerPCRunAt(r *Run, epoch uint64) bool {
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	if epoch != s.pcEpoch {
		return false
	}
	s.addPCRunLocked(r)
	return true
}
func (s *Server) pcCheckLocked(ctx context.Context, r *Run) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if r.pcEpoch != s.pcEpoch {
		return errors.New("PC control was stopped; start a new task")
	}
	return nil
}
func (s *Server) autoApprove(ctx context.Context, r *Run) bool {
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	if !r.localOperator || s.pcForceAsk || s.pcCheckLocked(ctx, r) != nil {
		return false
	}
	// Both machine-level consent AND the individual agent's explicit opt-in
	// are required for unattended writes. Existing non-agent run fixtures
	// continue to honor the machine policy.
	if r.AgentID!="" && !r.agentAutoAllow {
		return false
	}
	policy, err := s.St.PCPolicy()
	return err == nil && policy.AlwaysAllow
}
func pcGuard(ctx context.Context, action func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	state, _ := ctx.Value(pcExecutionKey{}).(pcExecution)
	if state.server == nil {
		return action()
	}
	s := state.server
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	if err := s.pcCheckLocked(ctx, state.run); err != nil {
		return err
	}
	if state.auto {
		p, err := s.St.PCPolicy()
		if err != nil || !p.AlwaysAllow || s.pcForceAsk {
			return errors.New("automatic permission was disabled before this action began")
		}
	}
	return action()
}
func pcStart(ctx context.Context, cmd *exec.Cmd) error { return pcGuard(ctx, cmd.Start) }

// Cancellation targets the complete child process group where supported.
func runPCCommand(ctx context.Context, command, dir string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := pcCommand(ctx, command)
	cmd.Dir = dir
	configurePCProcess(cmd)
	output := &pcOutput{}
	cmd.Stdout = output
	cmd.Stderr = output
	cmd.WaitDelay = 2 * time.Second
	if err := pcStart(ctx, cmd); err != nil {
		return "", err
	}
	err := cmd.Wait()
	if ctx.Err() != nil {
		_ = killPCProcessTree(cmd)
	}
	return output.String(), err
}

type pcOutput struct {
	mu   sync.Mutex
	data strings.Builder
}

func (b *pcOutput) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	remaining := (16 << 10) - b.data.Len()
	if remaining > 0 {
		if len(p) > remaining {
			p = p[:remaining]
		}
		b.data.Write(p)
	}
	return n, nil
}
func (b *pcOutput) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.data.String() }
