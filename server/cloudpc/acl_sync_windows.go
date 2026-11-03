//go:build windows

package main

// Windows builds support isolated development fixtures. Production Cloud PC
// uses Linux directory fsync; Windows does not establish that durability proof.
func syncACLDirectory(string) error { return nil }
