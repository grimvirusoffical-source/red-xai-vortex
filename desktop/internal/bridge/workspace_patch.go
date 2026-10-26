package bridge

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type patchReview struct {
	Files       []string `json:"files"`
	Additions   int      `json:"additions"`
	Deletions   int      `json:"deletions"`
	CheckPassed bool     `json:"checkPassed"`
	CheckError  string   `json:"checkError,omitempty"`
}

func validatePatch(root, patch string) (patchReview, error) {
	review := patchReview{Files: []string{}}
	if len(patch) == 0 || len(patch) > 256<<10 {
		return review, errors.New("provide a unified text patch up to 256 KiB")
	}
	if !filepath.IsAbs(root) {
		return review, errors.New("save an absolute repository path in this chat's coding context first")
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return review, errors.New("repository folder unavailable")
	}
	seen := map[string]bool{}
	oldPath := ""
	for _, line := range strings.Split(patch, "\n") {
		if strings.HasPrefix(line, "diff --git ") {
			fields := strings.Fields(line)
			if len(fields) != 4 || !strings.HasPrefix(fields[2], "a/") || !strings.HasPrefix(fields[3], "b/") {
				return review, errors.New("patch diff headers must use plain relative file paths")
			}
			old, new := fields[2][2:], fields[3][2:]
			if old != new || excludedCodePath(old) || filepath.IsAbs(old) || strings.HasPrefix(filepath.Clean(old), "..") {
				return review, errors.New("patch diff header targets an excluded or renamed path")
			}
		}
		if strings.HasPrefix(line, "GIT binary patch") || strings.HasPrefix(line, "Binary files ") || strings.HasPrefix(line, "rename ") || strings.HasPrefix(line, "copy ") || strings.Contains(line, "mode 120000") || strings.Contains(line, "mode 160000") {
			return review, errors.New("binary, symlink, submodule and rename patches are not supported by this review flow")
		}
		if strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") {
			raw := strings.TrimPrefix(strings.TrimPrefix(line, "+++ "), "--- ")
			if raw == line {
				return review, errors.New("invalid patch file header")
			}
			raw = strings.Split(raw, "\t")[0]
			if raw == "/dev/null" {
				if strings.HasPrefix(line, "---") {
					oldPath = ""
				}
				continue
			}
			if strings.HasPrefix(raw, "\"") {
				return review, errors.New("quoted patch paths are not supported; use a plain relative path")
			}
			if strings.HasPrefix(raw, "a/") || strings.HasPrefix(raw, "b/") {
				raw = raw[2:]
			}
			clean := filepath.Clean(raw)
			if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) || excludedCodePath(clean) {
				return review, errors.New("patch targets an excluded or out-of-repository path")
			}
			if strings.HasPrefix(line, "---") {
				oldPath = clean
			} else if oldPath != "" && oldPath != clean {
				return review, errors.New("renamed file paths are not supported")
			}
			target := filepath.Join(resolved, clean)
			parent := filepath.Dir(target)
			for {
				parentInfo, e := os.Lstat(parent)
				if e == nil {
					if parentInfo.Mode()&os.ModeSymlink != 0 {
						return review, errors.New("patch target has a symlink parent")
					}
					actual, e := filepath.EvalSymlinks(parent)
					if e != nil {
						return review, errors.New("patch parent unavailable")
					}
					rel, e := filepath.Rel(resolved, actual)
					if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || excludedCodePath(rel) {
						return review, errors.New("patch parent escapes the selected repository")
					}
					break
				}
				if !os.IsNotExist(e) {
					return review, e
				}
				next := filepath.Dir(parent)
				if next == parent {
					return review, errors.New("patch parent unavailable")
				}
				parent = next
			}
			if info, e := os.Lstat(target); e == nil && !info.Mode().IsRegular() {
				return review, errors.New("patch target must be a regular file")
			}
			if !seen[clean] {
				seen[clean] = true
				review.Files = append(review.Files, filepath.ToSlash(clean))
				if len(review.Files) > 32 {
					return review, errors.New("patch may change at most 32 files")
				}
			}
		} else if strings.HasPrefix(line, "+") {
			review.Additions++
		} else if strings.HasPrefix(line, "-") {
			review.Deletions++
		}
	}
	if len(review.Files) == 0 {
		return review, errors.New("patch contains no unified file headers")
	}
	return review, nil
}
func runGitPatch(root, patchPath string, check bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	args := []string{"--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", root, "apply", "--whitespace=nowarn"}
	if check {
		args = append(args, "--check")
	}
	args = append(args, "--", patchPath)
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0")
	if err := cmd.Run(); err != nil {
		return errors.New("patch did not apply cleanly to the current repository files; refresh the diff and review it again")
	}
	return nil
}
func (s *Server) workspacePatchAction(in map[string]any) map[string]any {
	chatID := str(in, "chatID")
	root := ""
	for _, c := range s.St.WorkspaceSnapshot().ChatSettings {
		if c.ChatID == chatID {
			root = c.Coding.RepoPath
			break
		}
	}
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved
	}
	patch := str(in, "patch")
	review, err := validatePatch(root, patch)
	if err != nil {
		return workspaceError(err)
	}
	dir := filepath.Join(s.St.Dir, "patches")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return workspaceError(err)
	}
	file, err := os.CreateTemp(dir, "review-*.patch")
	if err != nil {
		return workspaceError(err)
	}
	path := file.Name()
	_ = file.Chmod(0600)
	_, err = file.WriteString(patch)
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(path)
		return workspaceError(err)
	}
	err = runGitPatch(root, path, true)
	review.CheckPassed = err == nil
	if err != nil {
		review.CheckError = err.Error()
	}
	if str(in, "action") == "coding.patch.review" {
		_ = os.Remove(path)
		return map[string]any{"ok": true, "review": review}
	}
	if !review.CheckPassed {
		_ = os.Remove(path)
		return workspaceError(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	approval := &Approval{ID: workspaceID("approval"), Tool: "apply_patch", What: fmt.Sprintf("Apply reviewed patch in %s: %s (+%d / -%d). Full patch is available in Activity.", root, strings.Join(review.Files, ", "), review.Additions, review.Deletions), decided: make(chan bool, 1)}
	run := &Run{ID: workspaceID("patch"), AgentID: "workspace-code", Agent: "Code patch", Task: "Apply reviewed repository patch", Status: "waiting", Started: time.Now().UTC(), ChatID: chatID, Pending: approval, cancel: cancel}
	runs.mu.Lock()
	runs.runs[run.ID] = run
	runs.mu.Unlock()
	if s.Act != nil {
		s.log(run, "approval.request", "apply_patch", approval.What, patch)
	}
	go func() {
		defer os.Remove(path)
		defer cancel()
		allow := false
		select {
		case allow = <-approval.decided:
		case <-ctx.Done():
		case <-time.After(10 * time.Minute):
		}
		result := "Patch cancelled; repository files were preserved."
		status := "stopped"
		if allow {
			if _, e := validatePatch(root, patch); e != nil {
				result = e.Error()
				status = "error"
			} else if e = runGitPatch(root, path, true); e != nil {
				result = e.Error()
				status = "error"
			} else if e = runGitPatch(root, path, false); e != nil {
				result = e.Error()
				status = "error"
			} else {
				result = "Applied the approved patch to " + strings.Join(review.Files, ", ") + ". Run the relevant tests before committing."
				status = "done"
			}
		}
		s.setRun(run, func() { run.Status = status; run.Result = result; run.Pending = nil; run.Ended = time.Now().UTC() })
		if s.Act != nil {
			s.log(run, "run.end", "apply_patch", result, "")
		}
	}()
	return map[string]any{"ok": true, "runID": run.ID, "review": review, "message": "Patch reviewed. Open Activity to Allow or Deny applying it."}
}
