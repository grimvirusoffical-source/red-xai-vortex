package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"runtime"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/bridge"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func main() {
	headless := flag.Bool("headless", false, "serve bridge only (no GUI)")
	flag.Parse()
	st := store.Open()
	srv, err := bridge.Start(st)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Vortex bridge on", srv.Addr)
	if *headless {
		select {}
	}
	openUI(srv.Addr)
	select {}
}

func openUI(url string) {
	// Prefer system browser / webview host. On Linux try webkit gtk app if present; else xdg-open.
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		_ = exec.Command("open", url).Start()
	default:
		if p, err := exec.LookPath("vortex-webview"); err == nil {
			_ = exec.Command(p, url).Start()
			return
		}
		_ = exec.Command("xdg-open", url).Start()
	}
}
