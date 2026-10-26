package bridge

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestEmbeddedHelperCacheRepairsTamperingWithoutDownloads(t *testing.T) {
	t.Setenv("VORTEX_HELPER_CACHE_DIR", filepath.Join(t.TempDir(), "cache"))
	before := BundledBaseHelper
	BundledBaseHelper = []byte("trusted-build-helper")
	t.Cleanup(func() { BundledBaseHelper = before })
	path, err := cachedBundledBaseHelper()
	if err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "trusted-build-helper" {
		t.Fatal("embedded helper not installed")
	}
	if runtime.GOOS != "windows" {
		if info, _ := os.Stat(path); info.Mode().Perm() != 0700 {
			t.Fatal("helper cache permissions are not private")
		}
	}
	_ = os.WriteFile(path, []byte("tampered"), 0700)
	repaired, err := cachedBundledBaseHelper()
	if err != nil || repaired != path {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "trusted-build-helper" {
		t.Fatal("tampered helper was trusted")
	}
}
