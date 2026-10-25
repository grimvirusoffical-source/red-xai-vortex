//go:build !rsx

package main

import (
	"crypto/rand"
	"crypto/sha256"
)

func randBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	_, err := rand.Read(b)
	return b, err
}

func sum256(b []byte) [32]byte { return sha256.Sum256(b) }
