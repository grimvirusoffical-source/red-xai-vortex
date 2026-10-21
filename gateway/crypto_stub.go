//go:build !rsx && !stdcrypto

package main

// Placeholder crypto backend. The gateway's key hashing and provider-key sealing are
// pluggable: implement these four functions (CSPRNG, HMAC-SHA256, and a 256-bit AEAD
// such as ChaCha20-Poly1305 with a 12-byte nonce) or build with -tags rsx.
// This stub refuses to run so a build without a real backend can never store keys unsafely.

import "errors"

const cryptoBackend = "none"

var errNoCrypto = errors.New("no crypto backend linked: build with -tags rsx or provide crypto_*.go")

func cbRandom(n int) ([]byte, error)                    { return nil, errNoCrypto }
func cbHMAC(key, msg []byte) [32]byte                   { panic(errNoCrypto) }
func cbSeal(key, nonce, aad, pt []byte) ([]byte, error) { return nil, errNoCrypto }
func cbOpen(key, nonce, aad, ct []byte) ([]byte, error) { return nil, errNoCrypto }
