package main

import (
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

var windowsShellExecute = syscall.NewLazyDLL("shell32.dll").NewProc("ShellExecuteW")

// ShellExecuteW uses the registered HTTP handler (the user's default browser).
// Unlike invoking rundll32 url.dll,FileProtocolHandler, it returns a launch
// result and does not depend on undocumented rundll32 argument handling.
func openDesktopUI(address string) error {
	if !safeDesktopURL(address) {
		return errors.New("refusing to open a non-local Vortex address")
	}
	verb, _ := syscall.UTF16PtrFromString("open")
	target, err := syscall.UTF16PtrFromString(address)
	if err != nil {
		return err
	}
	result, _, _ := windowsShellExecute.Call(
		0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(target)),
		0, 0, 1,
	)
	runtime.KeepAlive(verb)
	runtime.KeepAlive(target)
	if result <= 32 {
		return fmt.Errorf("Windows ShellExecuteW failed (status %d): default browser may be unavailable", result)
	}
	return nil
}
