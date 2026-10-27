package bridge

import (
	"strings"
	"testing"
)

func TestChatGatewayErrorExplainsForbiddenWithoutDisablingProtection(t *testing.T) {
	for _, reason := range []string{
		"this key may not use model vortex-mini",
		"key lacks scope chat",
		"IP not allowed for this key",
		"device or IP banned",
	} {
		raw := []byte(`{"error":{"message":"` + reason + `"}}`)
		msg := chatGatewayError(403, raw)
		if !strings.Contains(msg, "HTTP 403") || !strings.Contains(msg, reason) {
			t.Fatalf("403 reason missing: %q", msg)
		}
		if !strings.Contains(msg, "administrator") {
			t.Fatalf("403 guidance must not suggest bypassing restrictions: %q", msg)
		}
	}
}

func TestChatGatewayErrorHandlesUnknownBodies(t *testing.T) {
	if msg := chatGatewayError(403, []byte("<html>forbidden</html>")); !strings.Contains(msg, "HTTP 403") {
		t.Fatal(msg)
	}
	if msg := chatGatewayError(401, nil); !strings.Contains(msg, "API key") {
		t.Fatal(msg)
	}
	if msg := chatGatewayError(404, []byte(`{"error":{"message":"model not installed"}}`)); !strings.Contains(msg, "model not installed") {
		t.Fatal(msg)
	}
}
