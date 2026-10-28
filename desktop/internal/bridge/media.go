package bridge

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// gw calls the Vortex gateway job queue (/v1/jobs) with the user's API key.
func (s *Server) gw(method, path string, body any) map[string]any {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, strings.TrimRight(s.St.Settings.BaseURL, "/")+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if k := s.secretGet("vortex-api-key"); k != "" {
		req.Header.Set("Authorization", "Bearer "+k)
	}
	res, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	out := map[string]any{}
	json.Unmarshal(b, &out)
	if res.StatusCode >= 300 {
		msg, _ := out["error"].(string)
		if m, ok := out["error"].(map[string]any); ok {
			msg, _ = m["message"].(string)
		}
		return map[string]any{"ok": false, "message": fmt.Sprintf("HTTP %d %s", res.StatusCode, msg)}
	}
	out["ok"] = true
	return out
}

// MediaSpec is everything needed to (re)generate one piece of media exactly.
type MediaSpec struct {
	Type     string  `json:"type"`               // image | speech | music | sfx | video
	Prompt   string  `json:"prompt"`             // prompt or text to speak
	Style    string  `json:"style,omitempty"`    // e.g. "watercolor", "photorealistic"
	Size     string  `json:"size,omitempty"`     // image WxH, 256-1024 (multiples of 64)
	Quality  string  `json:"quality,omitempty"`  // draft | standard | high
	Format   string  `json:"format,omitempty"`   // image: png | jpeg ; audio: wav ; video: mp4
	Duration float64 `json:"duration,omitempty"` // music 1-30s, sfx 1-10s
	Speed    float64 `json:"speed,omitempty"`    // speech 0.5-2
	Frames   int     `json:"frames,omitempty"`   // video 8-24 (8 fps)
	ChatID   string  `json:"chatID,omitempty"`   // in-chat generation: the chat to post into
	From     string  `json:"from,omitempty"`     // regenerated/redesigned from this media id
}

var mediaTypes = map[string]bool{"image": true, "speech": true, "music": true, "sfx": true, "video": true}
var sizeRe = regexp.MustCompile(`^(\d{3,4})x(\d{3,4})$`)

func (m *MediaSpec) normalize() error {
	m.Type = strings.ToLower(strings.TrimSpace(m.Type))
	m.Prompt = strings.TrimSpace(m.Prompt)
	if !mediaTypes[m.Type] {
		return fmt.Errorf("type must be image, speech, music, sfx or video")
	}
	if m.Prompt == "" {
		return fmt.Errorf("prompt required")
	}
	switch m.Quality {
	case "draft", "standard", "high":
	default:
		m.Quality = "standard"
	}
	switch m.Type {
	case "image":
		if m.Size == "" {
			m.Size = "512x512"
		}
		g := sizeRe.FindStringSubmatch(strings.ToLower(m.Size))
		if g == nil {
			return fmt.Errorf("size must be WIDTHxHEIGHT, e.g. 768x512")
		}
		w, _ := strconv.Atoi(g[1])
		h, _ := strconv.Atoi(g[2])
		if w < 256 || w > 1024 || h < 256 || h > 1024 {
			return fmt.Errorf("image size must be between 256 and 1024 on each side")
		}
		m.Size = fmt.Sprintf("%dx%d", w/64*64, h/64*64)
		if m.Format != "jpeg" && m.Format != "jpg" {
			m.Format = "png"
		} else {
			m.Format = "jpeg"
		}
	case "video":
		m.Format, m.Size = "mp4", "256x256"
		if m.Frames == 0 {
			m.Frames = 16
		}
		if m.Frames < 8 || m.Frames > 24 {
			return fmt.Errorf("video frames must be 8-24 (8 fps)")
		}
	default:
		m.Format = "wav"
		if m.Type == "music" && (m.Duration < 1 || m.Duration > 30) {
			m.Duration = 8
		}
		if m.Type == "sfx" && (m.Duration < 1 || m.Duration > 10) {
			m.Duration = 5
		}
		if m.Type == "speech" && (m.Speed < 0.5 || m.Speed > 2) {
			m.Speed = 1
		}
	}
	return nil
}

func (m MediaSpec) steps() int {
	return map[string]int{"draft": 4, "standard": 8, "high": 20}[m.Quality]
}
func (m MediaSpec) jpegQ() int {
	return map[string]int{"draft": 70, "standard": 85, "high": 95}[m.Quality]
}

func (m MediaSpec) gatewayBody() map[string]any {
	p := m.Prompt
	if m.Style != "" && m.Type != "speech" {
		p += ", " + m.Style + " style"
	}
	b := map[string]any{"type": m.Type, "prompt": p}
	switch m.Type {
	case "image":
		b["size"], b["steps"] = m.Size, m.steps()
	case "video":
		b["frames"] = m.Frames
	case "speech":
		b["input"], b["speed"] = p, m.Speed
	default:
		b["duration"] = m.Duration
	}
	return b
}

// Local media library: <config>/media/<jobid>.<ext> + <jobid>.json (spec + info).
type mediaRec struct {
	ID      string         `json:"id"`
	Spec    MediaSpec      `json:"spec"`
	Status  string         `json:"status"`
	File    string         `json:"file,omitempty"`
	Mime    string         `json:"mime,omitempty"`
	Info    map[string]any `json:"info,omitempty"`
	Error   string         `json:"error,omitempty"`
	Created time.Time      `json:"created"`
}

var media struct {
	sync.Mutex
	recs map[string]*mediaRec
}

func (s *Server) mediaDir() string {
	d := filepath.Join(s.St.Dir, "media")
	os.MkdirAll(d, 0700)
	return d
}

func (s *Server) mediaRec(id string) *mediaRec {
	media.Lock()
	defer media.Unlock()
	if media.recs == nil {
		media.recs = map[string]*mediaRec{}
	}
	if r := media.recs[s.St.Dir+"\x00"+id]; r != nil {
		return r
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`).MatchString(id) {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(s.mediaDir(), id+".json"))
	if err != nil {
		return nil
	}
	r := &mediaRec{}
	if json.Unmarshal(b, r) != nil {
		return nil
	}
	media.recs[s.St.Dir+"\x00"+id] = r
	return r
}

func (s *Server) saveRec(r *mediaRec) {
	media.Lock()
	if media.recs == nil {
		media.recs = map[string]*mediaRec{}
	}
	media.recs[s.St.Dir+"\x00"+r.ID] = r
	b, _ := json.MarshalIndent(r, "", " ")
	media.Unlock()
	os.WriteFile(filepath.Join(s.mediaDir(), r.ID+".json"), b, 0600)
}

func specFrom(in map[string]any) MediaSpec {
	b, _ := json.Marshal(in)
	var m MediaSpec
	json.Unmarshal(b, &m)
	if v, ok := in["spec"].(map[string]any); ok {
		b, _ = json.Marshal(v)
		json.Unmarshal(b, &m)
	}
	return m
}

// mediaSubmit queues a generation with an exact spec. With chatID, the result is posted into that chat.
func (s *Server) mediaSubmit(in map[string]any) map[string]any {
	m := specFrom(in)
	if err := m.normalize(); err != nil {
		return map[string]any{"ok": false, "message": err.Error()}
	}
	r := s.gw("POST", "/jobs", m.gatewayBody())
	if r["ok"] != true {
		return r
	}
	id, _ := r["id"].(string)
	if id == "" {
		return map[string]any{"ok": false, "message": "gateway returned no job id"}
	}
	s.saveRec(&mediaRec{ID: id, Spec: m, Status: "queued", Created: time.Now()})
	if m.ChatID != "" {
		s.postChat(m.ChatID, "user", "/"+m.Type+" "+m.Prompt+specSuffix(m))
		s.postChat(m.ChatID, "assistant", "[[media:"+id+"]]")
		go s.mediaWatch(id)
	}
	r["spec"] = m
	return r
}

func specSuffix(m MediaSpec) string {
	var p []string
	switch m.Type {
	case "image":
		p = append(p, "--size "+m.Size, "--quality "+m.Quality, "--format "+m.Format)
	case "video":
		p = append(p, "--frames "+strconv.Itoa(m.Frames))
	case "speech":
		p = append(p, "--speed "+strconv.FormatFloat(m.Speed, 'f', -1, 64))
	default:
		p = append(p, "--duration "+strconv.FormatFloat(m.Duration, 'f', -1, 64))
	}
	if m.Style != "" {
		p = append(p, "--style "+strconv.Quote(m.Style))
	}
	return " " + strings.Join(p, " ")
}

func (s *Server) postChat(chatID, role, content string) {
	for i := range s.St.Chats {
		if s.St.Chats[i].ID == chatID {
			c := s.St.Chats[i]
			c.Messages = append(c.Messages, store.Msg{Role: role, Content: content})
			if c.Title == "New chat" && role == "user" {
				t := content
				if len(t) > 40 {
					t = t[:40] + "…"
				}
				c.Title = t
			}
			s.St.SaveChat(c)
			return
		}
	}
}

// mediaWatch polls a job until it finishes so in-chat media is saved even if no viewer is open.
func (s *Server) mediaWatch(id string) {
	for i := 0; i < 1200; i++ {
		if !s.profileLive() {
			return
		}
		r := s.mediaJob(id)
		if st, _ := r["status"].(string); st == "done" || st == "failed" || st == "error" {
			return
		}
		time.Sleep(2 * time.Second)
	}
}

// mediaJob fetches job status; when done it saves the file locally (converting to the requested
// format) and returns the media with its real dimensions/format/quality.
func (s *Server) mediaJob(id string) map[string]any {
	rec := s.mediaRec(id)
	if rec != nil && rec.Status == "done" {
		return s.mediaOut(rec)
	}
	r := s.gw("GET", "/jobs/"+id, nil)
	if r["ok"] != true {
		if rec != nil {
			return s.mediaOut(rec)
		}
		return r
	}
	st, _ := r["status"].(string)
	if rec == nil { // job queued elsewhere (e.g. older client): adopt it
		t, _ := r["type"].(string)
		rec = &mediaRec{ID: id, Spec: MediaSpec{Type: t, Prompt: "(unknown prompt)", Format: map[string]string{"image": "png", "video": "mp4"}[t]}, Created: time.Now()}
		if rec.Spec.Format == "" {
			rec.Spec.Format = "wav"
		}
	}
	rec.Status = st
	if st == "done" {
		res, _ := r["result"].(map[string]any)
		b64, _ := res["b64"].(string)
		mime, _ := res["mime"].(string)
		data, err := base64.StdEncoding.DecodeString(b64)
		if err != nil || len(data) == 0 {
			rec.Status, rec.Error = "failed", "empty result"
		} else {
			data, mime, rec.Info = convertMedia(rec.Spec, data, mime)
			if meta, ok := res["meta"].(map[string]any); ok {
				for k, v := range meta {
					if _, have := rec.Info[k]; !have && k != "steps" {
						rec.Info[k] = v
					}
				}
			}
			if sec, ok := r["seconds"].(float64); ok {
				rec.Info["seconds"] = sec
			}
			ext := map[string]string{"image/png": "png", "image/jpeg": "jpg", "audio/wav": "wav", "video/mp4": "mp4"}[mime]
			if ext == "" {
				ext = "bin"
			}
			rec.File = filepath.Join(s.mediaDir(), id+"."+ext)
			rec.Mime = mime
			os.WriteFile(rec.File, data, 0600)
		}
	}
	if st == "failed" || st == "error" {
		rec.Error, _ = r["error"].(string)
	}
	s.saveRec(rec)
	out := s.mediaOut(rec)
	for _, k := range []string{"progress", "position", "seconds"} {
		if v, ok := r[k]; ok {
			out[k] = v
		}
	}
	return out
}

func (s *Server) mediaOut(r *mediaRec) map[string]any {
	out := map[string]any{"ok": true, "id": r.ID, "status": r.Status, "type": r.Spec.Type, "spec": r.Spec, "info": r.Info, "error": r.Error}
	if r.Status == "done" && r.File != "" {
		if b, err := os.ReadFile(r.File); err == nil {
			out["result"] = map[string]any{"b64": base64.StdEncoding.EncodeToString(b), "mime": r.Mime}
			out["file"] = r.File
			out["filename"] = "vortex-" + r.Spec.Type + "-" + r.ID + filepath.Ext(r.File)
		}
	}
	return out
}

// convertMedia applies the requested output format and measures the result.
func convertMedia(m MediaSpec, data []byte, mime string) ([]byte, string, map[string]any) {
	info := map[string]any{"format": strings.ToUpper(m.Format), "quality": m.Quality, "bytes": len(data)}
	if m.Style != "" {
		info["style"] = m.Style
	}
	switch {
	case strings.HasPrefix(mime, "image/"):
		img, _, err := image.Decode(bytes.NewReader(data))
		if err == nil {
			b := img.Bounds()
			info["width"], info["height"] = b.Dx(), b.Dy()
			info["steps"] = m.steps()
			if m.Format == "jpeg" {
				var buf bytes.Buffer
				if jpeg.Encode(&buf, img, &jpeg.Options{Quality: m.jpegQ()}) == nil {
					data, mime = buf.Bytes(), "image/jpeg"
					info["jpegQuality"] = m.jpegQ()
				}
			}
		}
	case mime == "audio/wav" && len(data) > 44:
		ch := binary.LittleEndian.Uint16(data[22:24])
		rate := binary.LittleEndian.Uint32(data[24:28])
		bits := binary.LittleEndian.Uint16(data[34:36])
		info["sampleRate"], info["channels"], info["bitDepth"] = rate, ch, bits
		if bps := int(rate) * int(ch) * int(bits) / 8; bps > 0 {
			info["duration"] = float64(len(data)-44) / float64(bps)
		}
	case mime == "video/mp4":
		info["width"], info["height"], info["fps"], info["frames"] = 256, 256, 8, m.Frames
		info["duration"] = float64(m.Frames) / 8
	}
	info["bytes"] = len(data)
	return data, mime, info
}

// mediaAgain re-runs a media item: "regenerate" keeps the exact spec (new seed), "redesign" applies changes.
func (s *Server) mediaAgain(in map[string]any, redesign bool) map[string]any {
	rec := s.mediaRec(str(in, "id"))
	if rec == nil {
		return map[string]any{"ok": false, "message": "media not found"}
	}
	m := rec.Spec
	if redesign {
		ch := specFrom(in)
		if ch.Prompt != "" {
			m.Prompt = ch.Prompt
		}
		if _, ok := in["style"]; ok {
			m.Style = ch.Style
		}
		if ch.Size != "" {
			m.Size = ch.Size
		}
		if ch.Quality != "" {
			m.Quality = ch.Quality
		}
		if ch.Format != "" {
			m.Format = ch.Format
		}
		if ch.Duration > 0 {
			m.Duration = ch.Duration
		}
		if ch.Speed > 0 {
			m.Speed = ch.Speed
		}
		if ch.Frames > 0 {
			m.Frames = ch.Frames
		}
	}
	m.From = rec.ID
	if c := str(in, "chatID"); c != "" {
		m.ChatID = c
	}
	b, _ := json.Marshal(m)
	var mm map[string]any
	json.Unmarshal(b, &mm)
	return s.mediaSubmit(mm)
}

func (s *Server) mediaJobs() map[string]any { return s.gw("GET", "/jobs", nil) }
