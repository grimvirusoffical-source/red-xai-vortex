package bridge

import (
	"encoding/base64"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	qrcode "github.com/skip2/go-qrcode"
	"strings"
	"sync"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"
)

// Secure chat (Red-SecretsXAI): chat goes through the bundled RedX Link helper, which
// seals every request with Red-SecretsXAI and carries all traffic as red-X barcode images.
// The helper is a prebuilt binary shipped next to the app; its source is private.

var linkListen = envOr("VORTEX_LINK_LISTEN", "127.0.0.1:18191")

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

var (
	linkMu   sync.Mutex
	linkProc *exec.Cmd
	linkArgs string
	linkErr  string
)

func helperPath() string {
	n := "redx-link"
	if runtime.GOOS == "windows" {
		n += ".exe"
	}
	if exe, err := os.Executable(); err == nil {
		if p := filepath.Join(filepath.Dir(exe), n); fileExists(p) {
			return p
		}
	}
	if p, err := exec.LookPath(n); err == nil {
		return p
	}
	return ""
}

func fileExists(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() }

// applyLink starts, restarts or stops the helper to match the settings.
func (s *Server) applyLink() {
	st := s.St.Settings
	linkMu.Lock()
	defer linkMu.Unlock()
	want := !st.PlainChat
	srv := st.LinkServer
	if srv == "" {
		srv = "45.77.105.187:8093"
	}
	args := []string{"proxy", "-listen", linkListen, "-servers", srv, "-barcode"}
	key := keyring.Get("vortex-api-key")
	sig := strings.Join(args, " ")
	if !want {
		sig = ""
	}
	if sig == linkArgs && linkProc != nil && linkProc.ProcessState == nil {
		return
	}
	if linkProc != nil && linkProc.Process != nil {
		linkProc.Process.Kill()
		linkProc.Wait()
		linkProc = nil
	}
	linkArgs, linkErr = sig, ""
	if sig == "" {
		return
	}
	bin := helperPath()
	if bin == "" {
		linkErr = "RedX Link helper missing; using direct HTTPS"
		return
	}
	c := exec.Command(bin, args...)
	c.Env = append(os.Environ(), "REDX_LINK_KEY="+key)
	if lf, err := os.Create(filepath.Join(s.St.Dir, "redx-link.log")); err == nil {
		c.Stderr = lf
	}
	hideWindow(c)
	if err := c.Start(); err != nil {
		linkErr = "could not start helper: " + err.Error()
		return
	}
	linkProc = c
	go c.Wait()
	for i := 0; i < 30; i++ {
		if cn, err := net.DialTimeout("tcp", linkListen, 100*time.Millisecond); err == nil {
			cn.Close()
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func linkUp() bool {
	linkMu.Lock()
	defer linkMu.Unlock()
	return linkProc != nil && linkProc.ProcessState == nil && linkErr == ""
}

// chatBase is where chat requests go: the helper when Secure chat is on and running, else direct.
func (s *Server) chatBase() string {
	if !s.St.Settings.PlainChat && linkUp() {
		return "http://" + linkListen + "/v1"
	}
	return strings.TrimRight(s.St.Settings.BaseURL, "/")
}

func (s *Server) linkStatus() map[string]any {
	m := map[string]any{"secure": !s.St.Settings.PlainChat && linkUp()}
	linkMu.Lock()
	m["error"] = linkErr
	linkMu.Unlock()
	if u, pin := phoneInfo(); u != "" {
		m["phoneURL"], m["phonePIN"] = u, pin
		if png, err := qrcode.Encode(u, qrcode.Medium, 256); err == nil {
			m["phoneQR"] = "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
		}
	}
	return m
}

func lanIP() string {
	c, err := net.Dial("udp", "10.255.255.255:9")
	if err != nil {
		return "this-pc"
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).IP.String()
}
