package update

import (
	"os"
	"path/filepath"
	"testing"
)

func TestHelperUpdatesInstallHostingAndPreserveFailedTarget(t *testing.T) {
	stage, installed := t.TempDir(), t.TempDir()
	for _, name := range []string{"redx-link", "vortex-base"} {
		_ = os.WriteFile(filepath.Join(stage, name), []byte("new-"+name), 0600)
		_ = os.WriteFile(filepath.Join(installed, name), []byte("old-"+name), 0700)
	}
	if err := installHelpers(stage, installed, []string{"redx-link", "vortex-base"}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"redx-link", "vortex-base"} {
		data, _ := os.ReadFile(filepath.Join(installed, name))
		if string(data) != "new-"+name {
			t.Fatalf("helper %s was omitted", name)
		}
		if info, _ := os.Stat(filepath.Join(installed, name)); info.Mode().Perm()&0100 == 0 {
			t.Fatal("helper is not executable")
		}
	}
	_ = os.Mkdir(filepath.Join(stage, "vortex-base"), 0700)
	if err := installHelpers(stage, installed, []string{"vortex-base"}); err == nil {
		t.Fatal("invalid staged helper accepted")
	}
	data, _ := os.ReadFile(filepath.Join(installed, "vortex-base"))
	if string(data) != "new-vortex-base" {
		t.Fatal("failed helper update removed installed helper")
	}
}
func TestLinuxInstalledExecutableAliasResolvesCanonicalPackage(t *testing.T) {
	stage := t.TempDir()
	_ = os.WriteFile(filepath.Join(stage, "vortex-linux-amd64"), []byte("new"), 0700)
	path, err := stagedExecutable(stage, "vortex")
	if err != nil || filepath.Base(path) != "vortex-linux-amd64" {
		t.Fatal("Linux installed executable alias is not updateable")
	}
}
func TestUnsignedBuildStillRefusesUpdate(t *testing.T) {
	old := Verifier
	Verifier = nil
	t.Cleanup(func() { Verifier = old })
	if err := Apply(&Release{}); err == nil {
		t.Fatal("unsigned build accepted an update")
	}
}

func TestSignedVersionRejectsReplayAndUnsignedTagMismatch(t *testing.T) {
	if err := validateSignedVersion([]byte(`{"version":"2.11"}`), "v2.11", "2.10"); err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []struct{ manifest, tag, installed string }{
		{`{"version":"2.8"}`, "v3.0", "2.10"},
		{`{"version":"2.8"}`, "v2.8", "2.10"},
		{`{"version":"2.10"}`, "v2.10", "2.10"},
		{`{}`, "v2.11", "2.10"},
	} {
		if validateSignedVersion([]byte(fixture.manifest), fixture.tag, fixture.installed) == nil {
			t.Fatalf("accepted replay or mismatched signed version: %+v", fixture)
		}
	}
}

func TestHistoricalSigningKeyCannotAuthorizeNewReleases(t *testing.T) {
	if !legacyReleaseVersionAllowed("2.8") || !legacyReleaseVersionAllowed("2.9") {
		t.Fatal("historical releases lost verification support")
	}
	for _, version := range []string{"2.10", "v2.11", "3.0"} {
		if legacyReleaseVersionAllowed(version) {
			t.Fatalf("lost old key can authorize new release %s", version)
		}
	}
}
