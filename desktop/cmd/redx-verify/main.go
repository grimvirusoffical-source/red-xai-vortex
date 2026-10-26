// redx-verify implements the existing native updater's three-path contract using
// the same pinned public release keys as the cross-platform updater.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/update"
)

func readBounded(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("verification input must be a regular file")
	}
	if info.Size() > limit {
		return nil, errors.New("verification input exceeds its size limit")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if int64(len(data)) > limit {
		return nil, errors.New("verification input exceeds its size limit")
	}
	return data, err
}
func verify(args []string) (string, error) {
	if len(args) != 3 {
		return "", errors.New("usage: redx-verify manifest sig asset")
	}
	manifest, err := readBounded(args[0], 1<<20)
	if err != nil {
		return "", err
	}
	signature, err := readBounded(args[1], 1024)
	if err != nil {
		return "", err
	}
	asset, err := readBounded(args[2], 1<<30)
	if err != nil {
		return "", err
	}
	if err = update.VerifyOfficialRelease(manifest, signature, filepath.Base(args[2]), asset); err != nil {
		return "", err
	}
	var document struct {
		Version string `json:"version"`
	}
	if err = json.Unmarshal(manifest, &document); err != nil {
		return "", err
	}
	return document.Version, nil
}
func main() {
	version, err := verify(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(version)
}
