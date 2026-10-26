package update

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
)

// This public trust key was recovered from the already trusted official
// redx-verify binary and checked against the existing 2.8 signed manifest and
// package. It is public verification material, never a private signing key.
const officialReleasePublicKey = "6979c5dfd027191f385aa9abad43666af27166156726865c235a45c71d096a4d"

// The owner approved this rotation after the old private signing key could not
// be located. Existing 2.8 clients require a manual update to cross that trust boundary.
const rotatedReleasePublicKey = "ea244ad764bc6556b93c5ca9a8e5075efc20dde9ac23ce26800be72bb2ece6e9"

type signedManifest struct {
	Version string            `json:"version"`
	Assets  map[string]string `json:"assets"`
}

func init() { Verifier = verifyOfficialRelease }
func decodeSignedManifest(publicKey, manifest, signature []byte) (signedManifest, error) {
	var document signedManifest
	if len(publicKey) != ed25519.PublicKeySize || len(manifest) == 0 || len(manifest) > 1<<20 || len(signature) > 1024 {
		return document, errors.New("invalid signed release manifest")
	}
	decoded, err := hex.DecodeString(strings.TrimSpace(string(signature)))
	if err != nil || len(decoded) != ed25519.SignatureSize || !ed25519.Verify(publicKey, manifest, decoded) {
		return document, errors.New("release manifest signature is invalid")
	}
	if err = json.Unmarshal(manifest, &document); err != nil || strings.TrimSpace(document.Version) == "" || len(document.Assets) == 0 {
		return document, errors.New("invalid signed release manifest")
	}
	return document, nil
}
func verifyReleaseWithPublicKey(publicKey, manifest, signature []byte, name string, data []byte) error {
	document, err := decodeSignedManifest(publicKey, manifest, signature)
	if err != nil {
		return err
	}
	expected, err := hex.DecodeString(document.Assets[name])
	if err != nil || len(expected) != sha256.Size {
		return errors.New("asset is missing from the signed release manifest")
	}
	actual := sha256.Sum256(data)
	if subtle.ConstantTimeCompare(expected, actual[:]) != 1 {
		return errors.New("asset does not match signed manifest")
	}
	return nil
}

func legacyReleaseVersionAllowed(version string) bool { return Newer("2.10", version) }

// VerifyOfficialRelease accepts the legacy key for historical releases and the
// owner-approved rotated key for future releases. The lost legacy key cannot
// authorize releases starting at 2.10.
func VerifyOfficialRelease(manifest, signature []byte, name string, data []byte) error {
	for index, encoded := range []string{officialReleasePublicKey, rotatedReleasePublicKey} {
		key, err := hex.DecodeString(encoded)
		if err != nil {
			continue
		}
		if document, decodeError := decodeSignedManifest(key, manifest, signature); decodeError == nil {
			if index == 0 && !legacyReleaseVersionAllowed(document.Version) {
				return errors.New("the historical signing key cannot authorize releases starting at 2.10")
			}
			return verifyReleaseWithPublicKey(key, manifest, signature, name, data)
		}
	}
	return errors.New("release manifest signature is invalid")
}
func verifyOfficialRelease(manifest, signature []byte, name string, data []byte) error {
	return VerifyOfficialRelease(manifest, signature, name, data)
}
