//go:build !windows

package main

import (
	"errors"
	"os/exec"
	"runtime"
)

func openDesktopUI(address string) error {
	if !safeDesktopURL(address) {
		return errors.New("refusing to open a non-local Vortex address")
	}
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", address).Start()
	default:
		if browser, err := exec.LookPath("vortex-webview"); err == nil {
			return exec.Command(browser, address).Start()
		}
		return exec.Command("xdg-open", address).Start()
	}
}
