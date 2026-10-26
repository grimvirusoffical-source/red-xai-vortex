package main

import "testing"

func TestEmbeddedPhoneHelperNeverSelfUpdates(t *testing.T) {
	if allowAutoUpdate(false, true) || allowAutoUpdate(true, true) ||
		allowAutoUpdate(true, false) || !allowAutoUpdate(false, false) {
		t.Fatal("hosted helpers must not modify a signed Mac app; standalone desktop updates remain enabled")
	}
}
