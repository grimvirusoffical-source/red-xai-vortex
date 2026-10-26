package ingest

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFetchRefusesPrivateServerBeforeSendingCredential(t *testing.T) {
	reached := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached = true; w.Write([]byte("private content")) }))
	defer server.Close()
	_, err := Fetch(context.Background(), server.URL, "test-credential")
	if err == nil || reached || strings.Contains(err.Error(), "test-credential") {
		t.Fatal("private destination/credential boundary failed")
	}
}

func TestDocumentNormalizationAndCredentialBoundaries(t *testing.T) {
	got, e := NormalizeURL("https://docs.google.com/document/d/abc_DEF-123/edit?usp=sharing#heading=h.one")
	if e != nil || got != "https://docs.google.com/document/d/abc_DEF-123/export?format=txt" {
		t.Fatalf("%s %v", got, e)
	}
	for _, raw := range []string{"http://example.com", "https://user:password@example.com/doc", "file:///etc/passwd", "https://example.com/doc?access_token=secret", "https://example.com/doc?api_key=secret"} {
		if _, e = NormalizeURL(raw); e == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	for _, key := range []string{"authorization", "jwt", "sig", "access_key", "resourcekey", "X-Amz-Credential", "X-Goog-Algorithm", "API.Key", "oauth_code", "session_id"} {
		if _, e = NormalizeURL("https://example.com/doc?" + key + "=fixture-private"); e == nil {
			t.Fatalf("credential query field accepted: %s", key)
		}
	}
	for _, raw := range []string{"127.0.0.1", "::1", "192.168.1.1", "10.0.0.1", "169.254.169.254", "0.0.0.0", "fe80::1", "224.0.0.1", "100.64.0.1", "198.18.0.1", "240.0.0.1", "2001:db8::1", "2002:a00:1::"} {
		if publicIP(net.ParseIP(raw)) {
			t.Fatalf("private destination %s", raw)
		}
	}
	if !publicIP(net.ParseIP("8.8.8.8")) {
		t.Fatal("public address refused")
	}
}
func TestHTMLExtractionAndInputBounds(t *testing.T) {
	text := TextHTML(`<h1 title="x > y">Guide &amp; notes</h1><script>steal()</script><style>hide{}</style><p>Use &lt;code&gt; safely.</p>`)
	if strings.Contains(text, "steal") || strings.Contains(text, "hide") || !strings.Contains(text, "Guide & notes") || !strings.Contains(text, "<code>") {
		t.Fatal(text)
	}
	if len(Clip(strings.Repeat("世", 100), 17)) > 17 {
		t.Fatal("invalid bound")
	}
	dir := t.TempDir()
	p := filepath.Join(dir, "notes.txt")
	os.WriteFile(p, []byte("document retrieval works"), 0600)
	result, e := Extract(context.Background(), p, "text/plain", Tools{})
	if e != nil || result.Text != "document retrieval works" || result.Method != "text" || result.SHA256 == "" {
		t.Fatalf("%+v %v", result, e)
	}
	if _, e = Extract(context.Background(), p, "image/png", Tools{}); e == nil {
		t.Fatal("invented image interpretation without OCR")
	}
	if _, e = Extract(context.Background(), dir, "text/plain", Tools{}); e == nil {
		t.Fatal("directory accepted")
	}
}
func TestCappedToolOutput(t *testing.T) {
	var b cappedBuffer
	n, e := b.Write([]byte(strings.Repeat("x", MaxText+100)))
	if e != nil || n != MaxText+100 || len(b.data) != MaxText || !b.overflow {
		t.Fatal("unbounded output")
	}
}
