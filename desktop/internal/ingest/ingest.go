// Package ingest turns explicitly selected sources into bounded, searchable text.
// It never evaluates document code or silently sends local files to a model service.
package ingest

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const MaxInput = 32 << 20
const MaxText = 1 << 20

type Result struct {
	Text      string    `json:"text"`
	Method    string    `json:"method"`
	Status    string    `json:"status"`
	SHA256    string    `json:"sha256"`
	Bytes     int64     `json:"bytes"`
	URL       string    `json:"url,omitempty"`
	CheckedAt time.Time `json:"checkedAt"`
}
type Tools struct {
	PDF          string `json:"pdf"`
	OCR          string `json:"ocr"`
	FFmpeg       string `json:"ffmpeg"`
	Whisper      string `json:"whisper"`
	WhisperModel string `json:"whisperModel,omitempty"`
}

func Detect(model string) Tools {
	return Tools{PDF: look("pdftotext"), OCR: look("tesseract"), FFmpeg: look("ffmpeg"), Whisper: look("whisper-cli"), WhisperModel: model}
}
func look(n string) string { p, _ := exec.LookPath(n); return p }
func Clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	s = s[:n]
	for !utf8.ValidString(s) && len(s) > 0 {
		s = s[:len(s)-1]
	}
	return s
}
func fingerprint(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func TextHTML(raw string) string {
	// Strip executable/non-content sections before a quote-aware tag scanner.
	for _, tag := range []string{"script", "style", "noscript", "svg"} {
		re := regexp.MustCompile("(?is)<" + tag + "\\b[^>]*>.*?</" + tag + "\\s*>")
		raw = re.ReplaceAllString(raw, "")
	}
	var out strings.Builder
	inTag := false
	var quote rune
	for _, r := range raw {
		if !inTag {
			if r == '<' {
				inTag = true
				out.WriteRune('\n')
			} else {
				out.WriteRune(r)
			}
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			}
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
		} else if r == '>' {
			inTag = false
		}
	}
	lines := []string{}
	for _, line := range strings.Split(html.UnescapeString(out.String()), "\n") {
		line = strings.Join(strings.Fields(line), " ")
		if line != "" {
			lines = append(lines, line)
		}
	}
	return Clip(strings.Join(lines, "\n"), MaxText)
}

// CredentialQueryKey applies the same normalized field policy to fetched and
// manually saved document citations. Values are never included in errors.
func CredentialQueryKey(key string) bool {
	k := strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, key)
	for _, part := range []string{"token", "secret", "password", "signature", "credential", "apikey"} {
		if strings.Contains(k, part) {
			return true
		}
	}
	switch k {
	case "key", "sig", "auth", "authorization", "jwt", "bearer", "accesskey", "resourcekey", "oauthcode", "code", "session", "sessionid", "sid", "ticket":
		return true
	}
	return strings.HasPrefix(k, "xamz") || strings.HasPrefix(k, "xgoog")
}
func NormalizeURL(raw string) (string, error) {
	u, e := url.Parse(strings.TrimSpace(raw))
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return "", errors.New("document sources require an HTTPS URL without embedded credentials")
	}
	query, queryError := url.ParseQuery(u.RawQuery)
	if queryError != nil {
		return "", errors.New("invalid document query fields")
	}
	for key := range query {
		if CredentialQueryKey(key) {
			return "", errors.New("put document access tokens in the separate credential field")
		}
	}
	if strings.EqualFold(u.Hostname(), "docs.google.com") {
		p := strings.Split(strings.Trim(u.Path, "/"), "/")
		if len(p) >= 3 && p[0] == "document" && p[1] == "d" {
			if !regexp.MustCompile(`^[A-Za-z0-9_-]+$`).MatchString(p[2]) {
				return "", errors.New("invalid Google document ID")
			}
			u.Path = "/document/d/" + p[2] + "/export"
			u.RawQuery = "format=txt"
		}
	}
	u.Fragment = ""
	return u.String(), nil
}
func publicIP(ip net.IP) bool {
	address, ok := netip.AddrFromSlice(ip)
	if !ok || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	address = address.Unmap()
	// GlobalUnicast also includes reserved, benchmark, shared carrier and
	// documentation networks. None is a public document destination.
	for _, raw := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "2001:db8::/32", "2001::/32", "2002::/16"} {
		if netip.MustParsePrefix(raw).Contains(address) {
			return false
		}
	}
	return address.Is4() || netip.MustParsePrefix("2000::/3").Contains(address)
}

// Fetch rejects private/metadata addresses at dial time as well as redirects.
// Authorization never follows a redirect. A private Google document can use an
// explicitly supplied Drive access token; OAuth sign-in is configured separately.
func Fetch(ctx context.Context, raw, token string) (Result, error) {
	normalized, e := NormalizeURL(raw)
	if e != nil {
		return Result{}, e
	}
	if strings.ContainsAny(token, "\r\n") || len(token) > 8192 {
		return Result{}, errors.New("invalid document credential")
	}
	target, _ := url.Parse(normalized)
	googleDocument := strings.EqualFold(target.Hostname(), "docs.google.com") && strings.HasPrefix(target.Path, "/document/d/")
	if googleDocument && token != "" {
		parts := strings.Split(strings.Trim(target.Path, "/"), "/")
		if len(parts) >= 3 {
			target = &url.URL{Scheme: "https", Host: "www.googleapis.com", Path: "/drive/v3/files/" + parts[2] + "/export", RawQuery: "mimeType=text%2Fplain"}
		}
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = func(c context.Context, network, address string) (net.Conn, error) {
		host, port, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		ips, e := net.DefaultResolver.LookupIP(c, "ip", host)
		if e != nil {
			return nil, e
		}
		if len(ips) == 0 {
			return nil, errors.New("document host unavailable")
		}
		for _, ip := range ips {
			if !publicIP(ip) {
				return nil, errors.New("private network document destinations are refused")
			}
		}
		return (&net.Dialer{Timeout: 8 * time.Second}).DialContext(c, network, net.JoinHostPort(ips[0].String(), port))
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, e := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if e != nil {
		return Result{}, errors.New("invalid document request")
	}
	request.Header.Set("Accept", "text/plain,text/html,application/pdf,application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, e := client.Do(request)
	if e != nil {
		return Result{}, errors.New("document fetch failed; check its access, hostname and TLS certificate")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return Result{}, fmt.Errorf("document fetch returned HTTP %d; redirects and sign-in pages are not imported", response.StatusCode)
	}
	data, e := io.ReadAll(io.LimitReader(response.Body, MaxInput+1))
	if e != nil || len(data) > MaxInput {
		return Result{}, errors.New("document exceeds the 32 MiB import limit")
	}
	mime := strings.ToLower(response.Header.Get("Content-Type"))
	result := Result{URL: normalized, SHA256: fingerprint(data), Bytes: int64(len(data)), CheckedAt: time.Now().UTC(), Status: "ready", Method: "document-text"}
	if strings.Contains(mime, "html") {
		if googleDocument {
			return Result{}, errors.New("Google document returned a page instead of exported text; check sharing or provide an authorized Drive token")
		}
		result.Text = TextHTML(string(data))
		result.Method = "document-html"
	} else if strings.HasPrefix(mime, "text/") || strings.Contains(mime, "json") || strings.Contains(mime, "xml") {
		if !utf8.Valid(data) {
			return Result{}, errors.New("document text is not UTF-8")
		}
		result.Text = Clip(string(data), MaxText)
	} else {
		return Result{}, errors.New("remote source is not text/HTML; download the file and use file extraction")
	}
	if strings.TrimSpace(result.Text) == "" {
		return Result{}, errors.New("document has no readable text")
	}
	return result, nil
}

type cappedBuffer struct {
	data     []byte
	overflow bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	room := MaxText - len(b.data)
	if len(p) > room {
		b.overflow = true
		p = p[:max(0, room)]
	}
	b.data = append(b.data, p...)
	return n, nil
}
func command(ctx context.Context, path string, args ...string) (string, error) {
	if path == "" {
		return "", errors.New("required local extraction tool is not installed")
	}
	cmd := exec.CommandContext(ctx, path, args...)
	var out cappedBuffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if e := cmd.Run(); e != nil {
		return "", errors.New("local extraction failed or timed out")
	}
	return Clip(string(out.data), MaxText), nil
}
func Extract(ctx context.Context, path, mime string, tools Tools) (Result, error) {
	file, e := os.Open(path)
	if e != nil {
		return Result{}, errors.New("attachment file unavailable")
	}
	defer file.Close()
	st, e := file.Stat()
	if e != nil || !st.Mode().IsRegular() || st.Size() > MaxInput {
		return Result{}, errors.New("select a regular file up to 32 MiB")
	}
	data, e := io.ReadAll(io.LimitReader(file, MaxInput+1))
	if e != nil || len(data) > MaxInput {
		return Result{}, errors.New("attachment could not be read")
	}
	result := Result{Status: "ready", SHA256: fingerprint(data), Bytes: int64(len(data)), CheckedAt: time.Now().UTC()}
	extension := strings.ToLower(filepath.Ext(path))
	text := ""
	switch {
	case strings.HasPrefix(mime, "text/") || strings.Contains(mime, "json") || strings.Contains(mime, "xml") || extension == ".md":
		if !utf8.Valid(data) {
			return result, errors.New("attachment text is not UTF-8")
		}
		text = string(data)
		result.Method = "text"
		if strings.Contains(mime, "html") {
			text = TextHTML(text)
			result.Method = "html"
		}
	case mime == "application/pdf" || extension == ".pdf":
		text, e = command(ctx, tools.PDF, "-layout", path, "-")
		result.Method = "pdf"
	case strings.HasPrefix(mime, "image/"):
		text, e = command(ctx, tools.OCR, path, "stdout")
		result.Method = "image-ocr"
	case strings.HasPrefix(mime, "audio/") || strings.HasPrefix(mime, "video/"):
		text, result.Method, e = extractMedia(ctx, path, mime, tools)
	default:
		return result, errors.New("no text extractor is available for this file type")
	}
	if e != nil {
		return result, e
	}
	result.Text = Clip(text, MaxText)
	if strings.TrimSpace(result.Text) == "" {
		return result, errors.New("the extractor found no readable text")
	}
	return result, nil
}

func extractMedia(ctx context.Context, path, mime string, tools Tools) (string, string, error) {
	temp, e := os.MkdirTemp("", "vortex-ingest-")
	if e != nil {
		return "", "", e
	}
	defer os.RemoveAll(temp)
	parts := []string{}
	audioOK := false
	framesOK := false
	if tools.Whisper != "" && tools.WhisperModel != "" && tools.FFmpeg != "" {
		wav := filepath.Join(temp, "audio.wav")
		if _, e = command(ctx, tools.FFmpeg, "-nostdin", "-y", "-i", path, "-vn", "-t", "600", "-ar", "16000", "-ac", "1", wav); e == nil {
			output := filepath.Join(temp, "transcript")
			if _, e = command(ctx, tools.Whisper, "-m", tools.WhisperModel, "-f", wav, "-otxt", "-of", output, "-nt"); e == nil {
				if b, e := os.ReadFile(output + ".txt"); e == nil && strings.TrimSpace(string(b)) != "" {
					parts = append(parts, "[Audio transcript]\n"+Clip(string(b), MaxText))
					audioOK = true
				}
			}
		}
	}
	if strings.HasPrefix(mime, "video/") && tools.OCR != "" && tools.FFmpeg != "" {
		pattern := filepath.Join(temp, "frame-%02d.png")
		if _, e = command(ctx, tools.FFmpeg, "-nostdin", "-y", "-i", path, "-vf", "fps=1/60,scale=1280:-1", "-frames:v", "10", pattern); e == nil {
			frames, _ := filepath.Glob(filepath.Join(temp, "frame-*.png"))
			for i, frame := range frames {
				caption, e := command(ctx, tools.OCR, frame, "stdout")
				if e == nil && strings.TrimSpace(caption) != "" {
					parts = append(parts, fmt.Sprintf("[Video frame %d, approximately %d seconds]\n%s", i+1, i*60, Clip(caption, 32000)))
					framesOK = true
				}
			}
		}
	}
	method := "audio-transcript"
	if framesOK {
		method = "video-frame-ocr"
		if audioOK {
			method = "video-transcript-and-frame-ocr"
		}
	}
	if !audioOK && !framesOK {
		return "", method, errors.New("no media text was extracted; audio needs ffmpeg, whisper-cli and a local model, and video frame OCR needs ffmpeg and tesseract")
	}
	return Clip(strings.Join(parts, "\n\n"), MaxText), method, nil
}
