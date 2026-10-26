package bridge

import (
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/update"
)

func (s *Server) manualUpdateCheck() map[string]any {
	r, err := update.Check()
	if err != nil {
		return map[string]any{"ok": false, "error": "Could not check GitHub releases: " + err.Error()}
	}
	if r == nil {
		return map[string]any{"ok": true, "available": false, "version": update.Version,
			"message": "Vortex " + update.Version + " is up to date."}
	}
	return map[string]any{"ok": true, "available": true, "version": r.Tag,
		"message": "Vortex " + r.Tag + " is available. Its signature is checked before installation."}
}

func (s *Server) manualUpdateStatus() map[string]any {
	s.updateMu.Lock()
	defer s.updateMu.Unlock()
	return map[string]any{"ok": true, "busy": s.updateBusy, "message": s.updateMessage}
}

func (s *Server) manualUpdateInstall() map[string]any {
	s.updateMu.Lock()
	if s.updateBusy {
		s.updateMu.Unlock()
		return map[string]any{"ok": true, "busy": true, "message": "A signed update is already being installed."}
	}
	s.updateBusy = true
	s.updateMessage = "Checking the current release before downloading…"
	s.updateMu.Unlock()
	go func() {
		fail := func(message string) {
			s.updateMu.Lock()
			s.updateMessage = message
			s.updateBusy = false
			s.updateMu.Unlock()
		}
		r, err := update.Check()
		if err != nil {
			fail("Release check failed: " + err.Error())
			return
		}
		if r == nil {
			fail("Vortex is already up to date.")
			return
		}
		s.updateMu.Lock()
		s.updateMessage = "Downloading and verifying the signed " + r.Tag + " release…"
		s.updateMu.Unlock()
		if err := update.Apply(r); err != nil {
			fail("Update failed: " + err.Error())
			return
		}
		s.updateMu.Lock()
		s.updateMessage = "Update installed. Restarting Vortex…"
		s.updateMu.Unlock()
		update.Relaunch()
		fail("The new binary was installed, but automatic restart failed. Restart Vortex manually.")
	}()
	return map[string]any{"ok": true, "busy": true, "message": "Installing the verified update…"}
}
