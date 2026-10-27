package bridge

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// chatGatewayError reports the actual server refusal instead of displaying an
// empty "(HTTP 403)" assistant message. A denial is never retried with a
// different key, model or identity: access policy remains server-owned.
func chatGatewayError(status int, raw []byte) string {
	var payload struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(raw, &payload)
	detail := strings.TrimSpace(payload.Error.Message)
	if len(detail) > 300 {
		detail = detail[:300]
	}
	if detail == "" {
		detail = http.StatusText(status)
	}
	switch status {
	case http.StatusUnauthorized:
		return fmt.Sprintf("Vortex authentication failed (HTTP 401): %s. Save a valid Vortex gateway API key under Settings > Connection.", detail)
	case http.StatusForbidden:
		return fmt.Sprintf("Vortex chat was denied (HTTP 403): %s. Check this key's allowed models, chat scope and IP access rules. An administrator must resolve any ban or restriction.", detail)
	default:
		return fmt.Sprintf("Vortex gateway returned HTTP %d: %s", status, detail)
	}
}
