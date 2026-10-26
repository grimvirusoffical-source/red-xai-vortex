package bridge

import (
	"context"
	"os"
	"os/exec"
	"strconv"
	"time"
)

func pcCommand(ctx context.Context, command string) *exec.Cmd {
	return exec.CommandContext(ctx, "cmd", "/C", command)
}
func configurePCProcess(cmd *exec.Cmd) { cmd.Cancel = func() error { return killPCProcessTree(cmd) } }
func killPCProcessTree(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return os.ErrProcessDone
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
	return cmd.Process.Kill()
}
