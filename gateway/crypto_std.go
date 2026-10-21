//go:build stdcrypto && !rsx

package main

// Portable backend using the Go standard library (CSPRNG, HMAC-SHA256, AES-256-GCM).
// Build with: go build -tags stdcrypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
)

const cryptoBackend = "stdlib"

func cbRandom(n int) ([]byte, error) { b := make([]byte, n); _, err := rand.Read(b); return b, err }
func cbHMAC(key, msg []byte) [32]byte {
	m := hmac.New(sha256.New, key)
	m.Write(msg)
	var o [32]byte
	copy(o[:], m.Sum(nil))
	return o
}
func aead(key []byte) (cipher.AEAD, error) {
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}
func cbSeal(key, nonce, aad, pt []byte) ([]byte, error) {
	a, err := aead(key)
	if err != nil {
		return nil, err
	}
	return a.Seal(nil, nonce, pt, aad), nil
}
func cbOpen(key, nonce, aad, ct []byte) ([]byte, error) {
	a, err := aead(key)
	if err != nil {
		return nil, err
	}
	return a.Open(nil, nonce, ct, aad)
}
