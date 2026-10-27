package bridge

import (
	"os"
	"path/filepath"
	"strings"
)

// When testing a different Red-XAI account, an owner/admin key must not
// silently skip the account gate after logout. This marker is per-installation
// and survives a restart; it never stores a token or alters chats/settings.
func (s *Server) accountSwitchPath() string {
	return filepath.Join(s.St.Dir, "redx-account-switch-required")
}

func (s *Server) accountSwitchRequired() bool {
	b, err := os.ReadFile(s.accountSwitchPath())
	return err == nil && strings.TrimSpace(string(b)) == "1"
}

func (s *Server) setAccountSwitchRequired(required bool) error {
	path := s.accountSwitchPath()
	if required {
		return os.WriteFile(path, []byte("1\n"), 0600)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
