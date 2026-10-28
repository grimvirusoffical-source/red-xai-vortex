package bridge

import (
	oskeyring "github.com/zalando/go-keyring"
	"os"
	"testing"
)

// Only test binaries use the mock OS store. Production has no fallback flag.
func TestMain(m *testing.M) { oskeyring.MockInit(); os.Exit(m.Run()) }
