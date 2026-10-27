package bridge

import (
	"strings"
	"testing"
)

func TestLinkSignatureTracksCredentialWithoutExposingIt(t *testing.T) {
	args := []string{"proxy", "-listen", "127.0.0.1:18191", "-servers", "example.org:8093", "-barcode"}
	key := "redx_ai_test-secret-must-not-appear"
	first := linkSignature(args, key)
	if strings.Contains(first, key) {
		t.Fatal("helper restart signature must not disclose the API key")
	}
	if first != linkSignature(args, key) {
		t.Fatal("same configuration should keep helper running")
	}
	if first == linkSignature(args, "redx_ai_different-test-key") {
		t.Fatal("replacing a key must restart the encrypted helper")
	}
	if first == linkSignature(args, "") {
		t.Fatal("setting a key after first launch must restart the encrypted helper")
	}
	if first == linkSignature([]string{"proxy", "-listen", "127.0.0.1:18191", "-servers", "elsewhere:8093", "-barcode"}, key) {
		t.Fatal("changing servers must restart the encrypted helper")
	}
}
