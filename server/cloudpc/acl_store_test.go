package main

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func TestConcurrentACLChangesRetainEveryRequestAndApproval(t *testing.T) {
	t.Setenv("CPC_ACL", filepath.Join(t.TempDir(), "acl.json"))
	const count = 40
	var workers sync.WaitGroup
	errors := make(chan error, count)
	for i := 0; i < count; i++ {
		workers.Add(1)
		go func(i int) {
			defer workers.Done()
			name := fmt.Sprintf("account-%d", i)
			errors <- mutateACL(func(a *aclFile) {
				a.Pending[name] = "fixture-time"
				a.Approved = append(a.Approved, name)
			})
		}(i)
	}
	workers.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	a, err := loadACL()
	if err != nil || len(a.Approved) != count || len(a.Pending) != count {
		t.Fatalf("lost permission changes: approvals=%d pending=%d error=%v", len(a.Approved), len(a.Pending), err)
	}
}

func TestACLRejectsCorruptionWithoutOverwritingOriginal(t *testing.T) {
	for _, content := range []string{"", "{", "null", `{"approved":["alice"]} trailing`, `{"approved":["alice"],"future":true}`} {
		t.Run(fmt.Sprintf("content-%d", len(content)), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "acl.json")
			t.Setenv("CPC_ACL", path)
			if err := os.WriteFile(path, []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
			called := false
			if err := mutateACL(func(a *aclFile) { called = true }); err == nil || called {
				t.Fatal("corrupt permissions admitted a mutation")
			}
			actual, err := os.ReadFile(path)
			if err != nil || string(actual) != content || isApproved("alice") {
				t.Fatal("corrupt permissions changed or granted access")
			}
		})
	}
}

func TestFailedPermissionMutationsNeverReturnSuccess(t *testing.T) {
	for _, route := range []string{"/request", "/approve", "/deny"} {
		t.Run(route, func(t *testing.T) {
			cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
			if route != "/request" {
				t.Setenv("CPC_OWNERS", "alice")
			}
			if err := os.WriteFile(aclPath(), []byte("{broken"), 0600); err != nil {
				t.Fatal(err)
			}
			r := cloudRequest(http.MethodPost, route)
			r.Header.Set("Origin", "https://cloud.example")
			r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			r.Body = http.NoBody
			r.Form = map[string][]string{"user": {"bob"}}
			w := httptest.NewRecorder()
			cloud(w, r)
			if w.Code != http.StatusServiceUnavailable || strings.Contains(w.Body.String(), "Approved bob") || strings.Contains(w.Body.String(), "Denied/revoked bob") {
				t.Fatalf("failed mutation acknowledged: status=%d body=%q", w.Code, w.Body.String())
			}
			actual, _ := os.ReadFile(aclPath())
			if string(actual) != "{broken" {
				t.Fatal("failed mutation overwrote original evidence")
			}
		})
	}
}

func TestPermissionReadFailureDeniesDesktopAndPermissionPage(t *testing.T) {
	current := cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
	current.port = "1"
	if err := os.Mkdir(aclPath(), 0700); err != nil {
		t.Fatal(err)
	}
	for _, route := range []string{"/", "/desktop/vnc_lite.html"} {
		w := httptest.NewRecorder()
		cloud(w, cloudRequest(http.MethodGet, route))
		if (route == "/" && w.Code != http.StatusServiceUnavailable) || (route != "/" && w.Code != http.StatusForbidden) {
			t.Fatalf("read error did not fail closed for %s: %d", route, w.Code)
		}
	}
}

func TestACLAtomicReplacementAndTemporaryFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "acl.json")
	t.Setenv("CPC_ACL", path)
	if err := saveACL(aclFile{Approved: []string{"alice"}}); err != nil {
		t.Fatal(err)
	}
	if err := mutateACL(func(a *aclFile) { a.Approved = nil; a.Pending["bob"] = "fixture-time" }); err != nil {
		t.Fatal(err)
	}
	a, err := loadACL()
	if err != nil || len(a.Approved) != 0 || a.Pending["bob"] != "fixture-time" {
		t.Fatalf("replacement not persisted: %v", err)
	}
	files, err := os.ReadDir(dir)
	if err != nil || len(files) != 1 || files[0].Name() != "acl.json" {
		t.Fatal("temporary permission files left behind")
	}
}

func TestACLUnwritablePathReturnsError(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "ordinary-file")
	if err := os.WriteFile(parent, []byte("preserve"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CPC_ACL", filepath.Join(parent, "acl.json"))
	if err := saveACL(aclFile{Approved: []string{"alice"}}); err == nil {
		t.Fatal("invalid parent acknowledged as a successful write")
	}
	actual, _ := os.ReadFile(parent)
	if string(actual) != "preserve" {
		t.Fatal("unrelated parent changed")
	}
}

func TestDirectoryFlushFailureDoesNotAcknowledgeOrNotify(t *testing.T) {
	for _, route := range []string{"/request", "/approve", "/deny"} {
		t.Run(route, func(t *testing.T) {
			cloudFixture(t, func(w http.ResponseWriter, r *http.Request) { accountResponse(w, "account-a", "alice") })
			if route != "/request" {
				t.Setenv("CPC_OWNERS", "alice")
			}
			initial := aclFile{Pending: map[string]string{"bob": "fixture-time"}}
			if route == "/deny" {
				initial.Approved = []string{"bob"}
			}
			if err := saveACL(initial); err != nil {
				t.Fatal(err)
			}
			var notifications atomic.Int32
			notify := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { notifications.Add(1); w.WriteHeader(200) }))
			t.Cleanup(notify.Close)
			t.Setenv("CPC_NOTIFY", notify.URL)
			t.Setenv("CPC_SMTP_HOST", "")
			previousSync := syncACLParent
			syncACLParent = func(string) error { return errors.New("fixture directory flush failed") }
			t.Cleanup(func() { syncACLParent = previousSync })
			r := cloudRequest(http.MethodPost, route)
			r.Header.Set("Origin", "https://cloud.example")
			r.Form = map[string][]string{"user": {"bob"}}
			w := httptest.NewRecorder()
			cloud(w, r)
			if w.Code != http.StatusServiceUnavailable || notifications.Load() != 0 {
				t.Fatalf("uncertain commit acknowledged/notified: %d, notifications=%d", w.Code, notifications.Load())
			}
			// Rename already happened. Do not pretend this is a rolled-back write.
			a, err := loadACL()
			if err != nil {
				t.Fatal(err)
			}
			if route == "/request" && a.Pending["alice"] == "" {
				t.Fatal("fixture did not reach replacement before the flush failure")
			}
			if route == "/approve" && (len(a.Approved) != 1 || a.Approved[0] != "bob") {
				t.Fatal("fixture did not reach approval replacement")
			}
			if route == "/deny" && len(a.Approved) != 0 {
				t.Fatal("fixture did not reach revocation replacement")
			}
		})
	}
}
