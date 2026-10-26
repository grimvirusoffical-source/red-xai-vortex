// Package update checks GitHub Releases, verifies the signed release manifest, installs and relaunches.
package update

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Version is set at build time: -ldflags "-X .../update.Version=2.2".
var Version = "2.2"

// API can be overridden with VORTEX_UPDATE_API (used for testing).
func api() string {
	if v := os.Getenv("VORTEX_UPDATE_API"); v != "" {
		return strings.TrimRight(v, "/")
	}
	return "https://api.github.com/repos/grimvirusoffical-source/red-xai-vortex"
}

type asset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}
type Release struct {
	Tag    string  `json:"tag_name"`
	Assets []asset `json:"assets"`
	Draft  bool    `json:"draft"`
	Pre    bool    `json:"prerelease"`
}

var cli = &http.Client{Timeout: 10 * time.Minute}

func Newer(a, b string) bool { // a > b
	p := func(s string) []int {
		var r []int
		for _, x := range strings.Split(strings.TrimPrefix(s, "v"), ".") {
			n, _ := strconv.Atoi(x)
			r = append(r, n)
		}
		return r
	}
	x, y := p(a), p(b)
	for i := 0; i < len(x) || i < len(y); i++ {
		var u, v int
		if i < len(x) {
			u = x[i]
		}
		if i < len(y) {
			v = y[i]
		}
		if u != v {
			return u > v
		}
	}
	return false
}

func assetName() string {
	if runtime.GOOS == "windows" {
		return "Red-XAI-Vortex-windows-amd64.zip"
	}
	return "Red-XAI-Vortex-linux-amd64.tar.gz"
}

// Check returns the latest release if it is newer than this build.
func Check() (*Release, error) {
	res, err := cli.Get(api() + "/releases/latest")
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("release check HTTP %d", res.StatusCode)
	}
	var r Release
	if err := json.NewDecoder(res.Body).Decode(&r); err != nil {
		return nil, err
	}
	if r.Draft || r.Pre || !Newer(r.Tag, Version) {
		return nil, nil
	}
	return &r, nil
}

func fetch(url string) ([]byte, error) {
	res, err := cli.Get(url)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("download HTTP %d", res.StatusCode)
	}
	return io.ReadAll(io.LimitReader(res.Body, 1<<30))
}

// Verifier checks a downloaded release package against the signed release manifest.
// Official builds register one at build time; when none is registered, updates are refused (fail closed).
// SHA256SUMS on the release page is public information only and is not trusted here.
var Verifier func(manifest, sig []byte, name string, data []byte) error

// Apply downloads, verifies the signed release manifest, installs over the running app and relaunches.
func Apply(r *Release) error {
	if Verifier == nil {
		return errors.New("this build cannot verify signed releases; download updates manually")
	}
	var pkg, man, sig string
	for _, a := range r.Assets {
		switch a.Name {
		case assetName():
			pkg = a.URL
		case "release-manifest.json":
			man = a.URL
		case "release-manifest.sig":
			sig = a.URL
		}
	}
	if pkg == "" || man == "" || sig == "" {
		return errors.New("release is missing the package or its signed manifest")
	}
	mb, err := fetch(man)
	if err != nil {
		return err
	}
	sb, err := fetch(sig)
	if err != nil {
		return err
	}
	data, err := fetch(pkg)
	if err != nil {
		return err
	}
	if err := Verifier(mb, sb, assetName(), data); err != nil {
		return errors.New("update rejected: " + err.Error())
	}
	exe, err := exePath()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	dir := filepath.Dir(exe)
	stage, err := os.MkdirTemp(dir, ".update-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	if runtime.GOOS == "windows" {
		err = unzip(data, stage)
	} else {
		err = untgz(data, stage)
	}
	if err != nil {
		return err
	}
	newExe := filepath.Join(stage, filepath.Base(exe))
	if _, err := os.Stat(newExe); err != nil {
		return errors.New("package does not contain " + filepath.Base(exe))
	}
	// rsx-runtime (bundled Python for secure chat): best-effort swap; if files are
	// in use (Windows) the previous runtime stays until the next update.
	if fi, err := os.Stat(filepath.Join(stage, "rsx-runtime")); err == nil && fi.IsDir() {
		old := filepath.Join(dir, "rsx-runtime")
		_ = os.RemoveAll(old + ".old")
		_ = os.Rename(old, old+".old")
		if err := os.Rename(filepath.Join(stage, "rsx-runtime"), old); err != nil {
			_ = os.Rename(old+".old", old)
		} else {
			_ = os.RemoveAll(old + ".old")
		}
	}
	// frontend: swap directory
	if fi, err := os.Stat(filepath.Join(stage, "frontend")); err == nil && fi.IsDir() {
		old := filepath.Join(dir, "frontend")
		_ = os.RemoveAll(old + ".old")
		_ = os.Rename(old, old+".old")
		if err := os.Rename(filepath.Join(stage, "frontend"), old); err != nil {
			_ = os.Rename(old+".old", old)
			return err
		}
		_ = os.RemoveAll(old + ".old")
	}
	// RedX Link helper (prebuilt, shipped next to the app): rename aside and replace
	for _, n := range []string{"redx-link", "redx-link.exe"} {
		if _, err := os.Stat(filepath.Join(stage, n)); err == nil {
			h := filepath.Join(dir, n)
			_ = os.Remove(h + ".old")
			_ = os.Rename(h, h+".old")
			if os.Rename(filepath.Join(stage, n), h) == nil {
				_ = os.Chmod(h, 0755)
			}
		}
	}
	// binary: rename running exe aside (works on Windows too), move new into place
	_ = os.Remove(exe + ".old")
	if err := os.Rename(exe, exe+".old"); err != nil {
		return err
	}
	if err := os.Rename(newExe, exe); err != nil {
		_ = os.Rename(exe+".old", exe)
		return err
	}
	_ = os.Chmod(exe, 0755)
	return nil
}

// Relaunch starts the new binary with the same args and exits.
// exePath is the installed executable path, even after the running file was renamed to .old.
func exePath() (string, error) {
	exe, err := os.Executable()
	return strings.TrimSuffix(exe, ".old"), err
}

func Relaunch() {
	exe, _ := exePath()
	cmd := exec.Command(exe, os.Args[1:]...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Start(); err == nil {
		os.Exit(0)
	}
}

func safe(dst, name string) (string, error) {
	p := filepath.Join(dst, name)
	if !strings.HasPrefix(p, filepath.Clean(dst)+string(os.PathSeparator)) {
		return "", errors.New("bad path in package")
	}
	return p, nil
}

func untgz(b []byte, dst string) error {
	gz, err := gzip.NewReader(strings.NewReader(string(b)))
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if filepath.Clean(h.Name) == "." {
			continue
		}
		p, err := safe(dst, h.Name)
		if err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(p, 0755)
		case tar.TypeReg:
			os.MkdirAll(filepath.Dir(p), 0755)
			f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(h.Mode)|0600)
			if err != nil {
				return err
			}
			_, err = io.Copy(f, tr)
			f.Close()
			if err != nil {
				return err
			}
		}
	}
}

func unzip(b []byte, dst string) error {
	zr, err := zip.NewReader(strings.NewReader(string(b)), int64(len(b)))
	if err != nil {
		return err
	}
	for _, f := range zr.File {
		p, err := safe(dst, f.Name)
		if err != nil {
			return err
		}
		if f.FileInfo().IsDir() {
			os.MkdirAll(p, 0755)
			continue
		}
		os.MkdirAll(filepath.Dir(p), 0755)
		rc, err := f.Open()
		if err != nil {
			return err
		}
		o, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0755)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(o, rc)
		o.Close()
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}
