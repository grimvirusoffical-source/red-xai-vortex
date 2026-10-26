package bridge

import (
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
	"testing"
)

func TestDocumentSourceFragmentsCannotStoreCredentials(t *testing.T) {
	for _, url := range []string{"https://example.com/doc#access_token=private", "https://example.com/doc#api_key=private", "https://example.com/doc#password=private"} {
		if err := validateSource(store.Source{Name: "Document", URL: url}); err == nil {
			t.Fatal("credential-bearing fragment accepted")
		}
	}
	if err := validateSource(store.Source{Name: "Document", URL: "https://docs.google.com/document/d/example/edit?usp=sharing#heading=h.example"}); err != nil {
		t.Fatal(err)
	}
}
