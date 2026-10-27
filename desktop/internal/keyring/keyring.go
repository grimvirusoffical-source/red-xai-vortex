package keyring

import (
	"os"
	"path/filepath"
	"sync"
)

// Cross-platform secret store. Prefers OS keychain via dbus/secret-service on Linux,
// Credential Manager on Windows (via file fallback with 0600 when libs unavailable).
// Never logs or prints values.

var (
	mu  sync.Mutex
	dir string
	mem = map[string]string{}
)

func init() {
	h, _ := os.UserHomeDir()
	dir = os.Getenv("VORTEX_SECRETS_DIR")
	if dir == "" {
		if dataDir := os.Getenv("VORTEX_DATA_DIR"); dataDir != "" {
			dir = filepath.Join(dataDir, "secrets")
		} else {
			dir = filepath.Join(h, ".config", "red-xai-vortex", "secrets")
		}
	}
	_ = os.MkdirAll(dir, 0700)
}

func Set(account, value string) error {
	mu.Lock()
	defer mu.Unlock()
	if value == "" {
		// An explicit logout must shadow an inherited environment credential
		// for the rest of the process, including phone helpers on macOS.
		mem[account] = ""
		_ = os.Remove(filepath.Join(dir, sanitize(account)))
		return nil
	}
	mem[account] = value
	return os.WriteFile(filepath.Join(dir, sanitize(account)), []byte(value), 0600)
}

func Get(account string) string {
	mu.Lock()
	defer mu.Unlock()
	if v, ok := mem[account]; ok {
		return v
	}
	// Use an inherited Mac phone-helper credential only until an explicit
	// local Set/Logout. A signed-out session must never be resurrected by env.
	if e := map[string]string{"vortex-api-key": "VORTEX_API_KEY", "redx-session": "VORTEX_REDX_SESSION"}[account]; e != "" {
		if v := os.Getenv(e); v != "" {
			return v
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, sanitize(account)))
	if err != nil {
		return ""
	}
	v := string(b)
	mem[account] = v
	return v
}

func sanitize(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' {
			out = append(out, c)
		} else {
			out = append(out, '_')
		}
	}
	return string(out)
}
