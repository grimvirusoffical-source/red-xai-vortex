package bridge

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestManualUpdateOnlyFromLocalSameOriginJSON(t *testing.T) {
	s := &Server{}
	cases := []struct {
		name, peer, origin string
		phone              bool
		want               int
	}{
		{"remote IP", "203.0.113.4:5000", "http://127.0.0.1:9999", false, 403},
		{"cross origin", "127.0.0.1:5000", "https://evil.example", false, 403},
		{"phone session", "127.0.0.1:5000", "http://127.0.0.1:9999", true, 403},
		{"local operator", "127.0.0.1:5000", "http://127.0.0.1:9999", false, 200},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "http://127.0.0.1:9999/bridge/update.status", strings.NewReader("{}"))
			req.RemoteAddr = c.peer
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Origin", c.origin)
			if c.phone {
				req = req.WithContext(context.WithValue(req.Context(), workspacePhoneSessionKey{}, true))
			}
			rec := httptest.NewRecorder()
			s.handle(rec, req)
			if rec.Code != c.want {
				t.Fatalf("got HTTP %d want %d, body=%s", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}
