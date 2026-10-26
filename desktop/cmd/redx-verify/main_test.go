package main

import (
	"path/filepath"
	"testing"
)

func TestVerifierCLIRejectsMissingArgumentsAndMismatchedPayload(t *testing.T) {
	if _, err := verify(nil); err == nil {
		t.Fatal("missing verification inputs accepted")
	}
	testdata := filepath.Join("..", "..", "internal", "update", "testdata")
	if _, err := verify([]string{filepath.Join(testdata, "v2.8-manifest.json"), filepath.Join(testdata, "v2.8-manifest.sig"), filepath.Join(testdata, "v2.8-manifest.json")}); err == nil {
		t.Fatal("signed manifest incorrectly authenticated unrelated payload")
	}
}
