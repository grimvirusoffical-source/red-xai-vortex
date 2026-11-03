package main

import (
	"net/http"
	"strings"
)

// Do not let Cookie() select the first of multiple session/flow credentials.
// Count raw selected names before parsing so an invalid duplicate cannot be
// silently discarded while another value establishes a session or flow.
func uniqueCookie(r *http.Request, name string) (*http.Cookie, error) {
	count := 0
	for _, header := range r.Header.Values("Cookie") {
		for _, part := range strings.Split(header, ";") {
			key, _, _ := strings.Cut(strings.TrimSpace(part), "=")
			if strings.TrimSpace(key) == name {
				count++
			}
		}
	}
	if count != 1 {
		return nil, http.ErrNoCookie
	}
	return r.Cookie(name)
}
