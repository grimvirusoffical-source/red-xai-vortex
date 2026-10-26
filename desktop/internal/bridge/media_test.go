package bridge

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

func TestMediaSpecNormalize(t *testing.T) {
	m := MediaSpec{Type: "image", Prompt: "fox", Size: "800x520", Format: "jpg", Quality: "high", Style: "watercolor"}
	if err := m.normalize(); err != nil {
		t.Fatal(err)
	}
	if m.Size != "768x512" || m.Format != "jpeg" || m.steps() != 20 {
		t.Fatalf("got %+v", m)
	}
	if b := m.gatewayBody(); b["prompt"] != "fox, watercolor style" || b["steps"] != 20 {
		t.Fatalf("body %v", b)
	}
	if (&MediaSpec{Type: "image", Prompt: "x", Size: "2000x10"}).normalize() == nil {
		t.Fatal("bad size accepted")
	}
	if (&MediaSpec{Type: "video", Prompt: "x", Frames: 40}).normalize() == nil {
		t.Fatal("bad frames accepted")
	}
}

func TestMediaJobJPEGAndRedesign(t *testing.T) {
	t.Setenv("VORTEX_DATA_DIR", t.TempDir())
	img := image.NewRGBA(image.Rect(0, 0, 768, 512))
	img.Set(1, 1, color.RGBA{255, 0, 0, 255})
	var pb bytes.Buffer
	png.Encode(&pb, img)
	var posted []map[string]any
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			var b map[string]any
			json.NewDecoder(r.Body).Decode(&b)
			posted = append(posted, b)
			json.NewEncoder(w).Encode(map[string]any{"id": "job" + string(rune('A'+len(posted))), "position": 1})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"status": "done", "type": "image", "result": map[string]any{"b64": base64.StdEncoding.EncodeToString(pb.Bytes()), "mime": "image/png"}})
	}))
	defer gw.Close()
	st := store.Open()
	st.Settings.BaseURL = gw.URL
	s := &Server{St: st}
	r := s.mediaSubmit(map[string]any{"type": "image", "prompt": "fox", "size": "768x512", "format": "jpeg", "quality": "high"})
	if r["ok"] != true {
		t.Fatal(r)
	}
	j := s.mediaJob(r["id"].(string))
	info := j["info"].(map[string]any)
	if j["status"] != "done" || info["width"] != 768 || info["height"] != 512 || info["format"] != "JPEG" || info["jpegQuality"] != 95 {
		t.Fatalf("info %v", info)
	}
	if j["result"].(map[string]any)["mime"] != "image/jpeg" {
		t.Fatal("not converted")
	}
	r2 := s.mediaAgain(map[string]any{"id": r["id"], "style": "oil paint", "size": "512x512"}, true)
	if r2["ok"] != true || posted[1]["size"] != "512x512" || posted[1]["prompt"] != "fox, oil paint style" {
		t.Fatalf("redesign %v %v", r2, posted)
	}
	s.mediaAgain(map[string]any{"id": r["id"]}, false)
	if posted[2]["size"] != "768x512" || posted[2]["steps"] != float64(20) {
		t.Fatalf("regenerate changed spec %v", posted[2])
	}
}
