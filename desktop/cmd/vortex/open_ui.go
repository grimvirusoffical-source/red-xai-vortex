package main

import (
	"net/url"
	"strconv"
)

// The desktop bridge is local-only. Never pass a remote or attacker-supplied
// address to the operating system's browser association mechanism.
func safeDesktopURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "http" || parsed.Hostname() != "127.0.0.1" || parsed.User != nil ||
		parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" {
		return false
	}
	port, err := strconv.Atoi(parsed.Port())
	return err == nil && port >= 1 && port <= 65535
}
