//go:build !windows

package bridge

import "os/exec"

func hideWindow(c *exec.Cmd) {}
