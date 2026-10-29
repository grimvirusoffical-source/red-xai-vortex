package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultBaseURLUsesPublicDNSGateway(t *testing.T) {
	st := OpenAt(t.TempDir())
	if st.Settings.BaseURL != DefaultBaseURL {
		t.Fatalf("default gateway = %q, want %q", st.Settings.BaseURL, DefaultBaseURL)
	}
}

func TestLegacyRawIPGatewayMigratesAndPersists(t *testing.T) {
	dir := t.TempDir()
	raw := []byte(`{"baseURL":"https://45.77.105.187/v1","activeAgent":"vortex-default"}`)
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	st := OpenAt(dir)
	if st.Settings.BaseURL != DefaultBaseURL {
		t.Fatalf("migrated gateway = %q, want %q", st.Settings.BaseURL, DefaultBaseURL)
	}
	var saved Settings
	b, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &saved); err != nil {
		t.Fatal(err)
	}
	if saved.BaseURL != DefaultBaseURL {
		t.Fatalf("persisted gateway = %q, want %q", saved.BaseURL, DefaultBaseURL)
	}
}

func TestCustomGatewayIsPreserved(t *testing.T) {
	dir := t.TempDir()
	raw := []byte(`{"baseURL":"https://custom.example/v1","activeAgent":"vortex-default"}`)
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	st := OpenAt(dir)
	if st.Settings.BaseURL != "https://custom.example/v1" {
		t.Fatalf("custom gateway changed to %q", st.Settings.BaseURL)
	}
}
