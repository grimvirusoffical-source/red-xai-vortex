package bridge

import (
	"crypto/tls"
	"crypto/x509"
	_ "embed"
	"net/http"
)

// The Red-XAI Vultr gateway uses a self-signed certificate (IP SAN 45.77.105.187).
// Trust it in addition to the system roots so API keys only travel over HTTPS.
//
//go:embed vultr-ca.pem
var vultrCA []byte

func init() {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	pool.AppendCertsFromPEM(vultrCA)
	if t, ok := http.DefaultTransport.(*http.Transport); ok {
		t.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
}
