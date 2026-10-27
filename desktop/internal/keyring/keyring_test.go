package keyring

import "testing"

func TestExplicitLogoutShadowsInheritedSession(t *testing.T) {
	t.Setenv("VORTEX_REDX_SESSION", "inherited-test-only-session")
	const account = "redx-session"
	mu.Lock()
	old, had := mem[account]
	oldDir := dir
	dir = t.TempDir() // never touch the real OS user's stored account token
	delete(mem, account)
	mu.Unlock()
	defer func() {
		mu.Lock()
		dir = oldDir
		if had { mem[account] = old } else { delete(mem, account) }
		mu.Unlock()
	}()
	if got := Get(account); got != "inherited-test-only-session" {
		t.Fatalf("environment session was not available before explicit logout")
	}
	if err := Set(account, ""); err != nil {
		t.Fatal(err)
	}
	if got := Get(account); got != "" {
		t.Fatal("environment resurrected a signed-out account")
	}
	if err := Set(account, "new-test-session"); err != nil {
		t.Fatal(err)
	}
	if got := Get(account); got != "new-test-session" {
		t.Fatal("new explicit login was shadowed by old environment token")
	}
	_ = Set(account, "")
}
