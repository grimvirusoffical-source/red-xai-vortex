package bridge

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

// BundledBaseHelper is registered by the official build's generated embed file.
// Keeping the helper inside the executable bootstraps first-hop updates from old
// Vortex updaters which did not install an additional helper from the archive.
// This never downloads code and never weakens release signature verification.
var BundledBaseHelper []byte

func cachedBundledBaseHelper() (string, error) {
	if len(BundledBaseHelper) == 0 {
		return "", errors.New("no embedded hosting helper")
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", errors.New("private helper cache unavailable")
	}
	hash := sha256.Sum256(BundledBaseHelper)
	name := "vortex-base"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	dir := filepath.Join(cache, "red-xai-vortex", "helpers", hex.EncodeToString(hash[:]))
	if err = os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	if err = os.Chmod(dir, 0700); err != nil {
		return "", err
	}
	path := filepath.Join(dir, name)
	if info, e := os.Lstat(path); e == nil && info.Mode().IsRegular() {
		if data, e := os.ReadFile(path); e == nil {
			actual := sha256.Sum256(data)
			if bytes.Equal(actual[:], hash[:]) {
				if e = os.Chmod(path, 0700); e == nil {
					return path, nil
				}
			}
		}
	}
	file, err := os.CreateTemp(dir, ".helper-*")
	if err != nil {
		return "", err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err = file.Chmod(0700); err == nil {
		_, err = file.Write(BundledBaseHelper)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return "", err
	}
	if info, e := os.Lstat(path); e == nil && !info.Mode().IsRegular() {
		return "", errors.New("invalid helper cache entry")
	}
	if err = os.Rename(temporary, path); err != nil {
		return "", err
	}
	return path, nil
}
