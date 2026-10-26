package update

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestExistingOfficialManifestTrustKeyIsPreserved(t *testing.T) {
	manifest, err := os.ReadFile("testdata/v2.8-manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	signature, _ := os.ReadFile("testdata/v2.8-manifest.sig")
	key, _ := hex.DecodeString(officialReleasePublicKey)
	document, err := decodeSignedManifest(key, manifest, signature)
	if err != nil || document.Version != "2.8" || document.Assets["Red-XAI-Vortex-linux-amd64.tar.gz"] != "d5ae6ff6aa986c3f478d88917a9643fe7f466492ef9d810ee9053f2dc85eaa9a" {
		t.Fatal("existing official release no longer verifies")
	}
	manifest[0] ^= 1
	if _, err := decodeSignedManifest(key, manifest, signature); err == nil {
		t.Fatal("tampered official manifest accepted")
	}
}
func TestReleaseVerificationRejectsTamperingAndWrongTrustKey(t *testing.T) {
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	payload := []byte("signed package contents")
	hash := sha256.Sum256(payload)
	manifest, _ := json.Marshal(signedManifest{Version: "2.10", Assets: map[string]string{"package.zip": hex.EncodeToString(hash[:])}})
	signature := []byte(hex.EncodeToString(ed25519.Sign(private, manifest)))
	if err := verifyReleaseWithPublicKey(public, manifest, signature, "package.zip", payload); err != nil {
		t.Fatal(err)
	}
	wrongPublic, _, _ := ed25519.GenerateKey(rand.Reader)
	for _, check := range []struct {
		key, manifest, signature, payload []byte
		name                              string
	}{{public, manifest, signature, []byte("tampered package"), "package.zip"}, {wrongPublic, manifest, signature, payload, "package.zip"}, {public, manifest, []byte("00"), payload, "package.zip"}, {public, manifest, signature, payload, "missing.zip"}} {
		if err := verifyReleaseWithPublicKey(check.key, check.manifest, check.signature, check.name, check.payload); err == nil {
			t.Fatal("modified release or wrong trust key accepted")
		}
	}
	if err := verifyOfficialRelease(manifest, signature, "package.zip", payload); err == nil {
		t.Fatal("a newly generated key was accepted as the official trust key")
	}
}
func TestActualLegacyPackageWhenProvided(t *testing.T) {
	dir := os.Getenv("VORTEX_LEGACY_RELEASE_TEST_DIR")
	if dir == "" {
		t.Skip("set VORTEX_LEGACY_RELEASE_TEST_DIR to validate the existing large release archive without storing it in Git")
	}
	manifest, err := os.ReadFile(filepath.Join(dir, "release-manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	signature, err := os.ReadFile(filepath.Join(dir, "release-manifest.sig"))
	if err != nil {
		t.Fatal(err)
	}
	name := "Red-XAI-Vortex-linux-amd64.tar.gz"
	payload, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	if err = verifyOfficialRelease(manifest, signature, name, payload); err != nil {
		t.Fatal(err)
	}
}
