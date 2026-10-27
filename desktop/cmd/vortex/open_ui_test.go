package main

import "testing"

func TestVortexDesktopURLAllowsOnlyLocalBridge(t *testing.T) {
	for _, u := range []string{"http://127.0.0.1:1011", "http://127.0.0.1:65535"} {
		if !safeDesktopURL(u) {
			t.Errorf("rejected bridge URL %q", u)
		}
	}
	for _, u := range []string{
		"", "http://127.0.0.1", "http://127.0.0.1:0",
		"http://localhost:1011", "https://red-xai.com/",
		"http://127.0.0.1:1@evil.example/", "http://127.0.0.1:1011/secret",
		"http://127.0.0.1:1011/?next=http://evil.invalid/",
		"http://127.0.0.1:65536", "javascript:alert(1)",
		"http://[::1]:1011",
	} {
		if safeDesktopURL(u) {
			t.Errorf("accepted non-local or invalid URL %q", u)
		}
	}
}
