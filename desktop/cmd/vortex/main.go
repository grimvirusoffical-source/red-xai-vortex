package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"runtime"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/bridge"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/update"
	"time"
)

func main() {
	headless := flag.Bool("headless", false, "serve bridge only (no GUI)")
	noUpdate := flag.Bool("no-update", false, "do not self-update (host app updates us)")
	phoneOnly := flag.Bool("phone", false, "serve phone access (implies -headless); secure chat from VORTEX_SECURE=0/1")
	flag.Parse()
	st := store.Open()
	if *phoneOnly {
		// This binary is embedded in the notarized Mac host. Only the host
		// updater may modify it; updating it in place invalidates the bundle.
		*noUpdate = true
		*headless = true
		ss := st.Settings
		ss.PhoneChat = true
		ss.PlainChat = os.Getenv("VORTEX_SECURE") == "0"
		if u := os.Getenv("VORTEX_BASE_URL"); u != "" {
			ss.BaseURL = u
		}
		st.SetSettings(ss)
		go func() { // exit with the host app
			for os.Getppid() != 1 {
				time.Sleep(2 * time.Second)
			}
			os.Exit(0)
		}()
	}
	srv, err := bridge.Start(st)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Vortex", update.Version, "bridge on", srv.Addr)
	if allowAutoUpdate(*noUpdate, *phoneOnly) {
		go autoUpdate(st)
	}
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

func allowAutoUpdate(disabled, hostedPhone bool) bool {
	return !disabled && !hostedPhone
}

// autoUpdate checks on launch and every 4 hours unless turned off in Settings.
func autoUpdate(st *store.Store) {
	for {
		if !st.Settings.NoAutoUpdate {
			if r, err := update.Check(); err != nil {
				fmt.Println("update check:", err)
			} else if r != nil {
				fmt.Println("update: installing", r.Tag)
				if err := update.Apply(r); err != nil {
					fmt.Println("update failed:", err)
				} else {
					fmt.Println("update: installed", r.Tag, "- relaunching")
					update.Relaunch()
				}
			}
		}
		time.Sleep(4 * time.Hour)
	}
}
