package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
)

// Immutable after startup. There are no implicitly trusted proxy addresses.
// Native TLS works without a proxy policy; cloudflared requires an explicitly
// allowlisted immediate peer and its strict HTTPS scheme assertion.
type trustedProxyPolicy struct{ networks []netip.Prefix }

var cpcProxyTrust trustedProxyPolicy

func parseTrustedProxies(value string) (trustedProxyPolicy, error) {
	policy := trustedProxyPolicy{}
	if strings.TrimSpace(value) == "" {
		return policy, nil
	}
	if len(value) > 16384 {
		return policy, errors.New("invalid CPC_TRUSTED_PROXY_CIDRS")
	}
	parts := strings.Split(value, ",")
	if len(parts) > 256 {
		return policy, errors.New("invalid CPC_TRUSTED_PROXY_CIDRS")
	}
	for _, part := range parts {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(part))
		if err != nil || prefix.Addr().Is4In6() {
			return trustedProxyPolicy{}, errors.New("invalid CPC_TRUSTED_PROXY_CIDRS; use explicit IPv4 or IPv6 CIDRs")
		}
		policy.networks = append(policy.networks, prefix.Masked())
	}
	return policy, nil
}

func immediatePeer(r *http.Request) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}, false
	}
	address, err := netip.ParseAddr(host)
	if err != nil || address.Zone() != "" {
		return netip.Addr{}, false
	}
	return address.Unmap(), true
}

func (policy trustedProxyPolicy) trusts(r *http.Request) bool {
	address, ok := immediatePeer(r)
	if !ok {
		return false
	}
	for _, network := range policy.networks {
		if network.Contains(address) {
			return true
		}
	}
	return false
}

func singleHeader(r *http.Request, name string, max int) (string, bool) {
	values := r.Header.Values(name)
	if len(values) != 1 || len(values[0]) == 0 || len(values[0]) > max || strings.TrimSpace(values[0]) != values[0] {
		return "", false
	}
	return values[0], true
}

func proxySaysHTTPS(r *http.Request) bool {
	value, ok := singleHeader(r, "CF-Visitor", 256)
	if !ok {
		return false
	}
	// Parse an exact one-member object. This rejects duplicate/case-varied keys,
	// extra fields, malformed JSON, non-string schemes and trailing data.
	d := json.NewDecoder(strings.NewReader(value))
	start, err := d.Token()
	if err != nil || start != json.Delim('{') {
		return false
	}
	key, err := d.Token()
	if err != nil || key != "scheme" {
		return false
	}
	scheme, err := d.Token()
	if err != nil || scheme != "https" {
		return false
	}
	end, err := d.Token()
	if err != nil || end != json.Delim('}') {
		return false
	}
	_, err = d.Token()
	return err == io.EOF
}

func secure(r *http.Request) bool {
	return r.TLS != nil || (cpcProxyTrust.trusts(r) && proxySaysHTTPS(r))
}

func clientIP(r *http.Request) string {
	if cpcProxyTrust.trusts(r) {
		if value, ok := singleHeader(r, "CF-Connecting-IP", 64); ok {
			if address, err := netip.ParseAddr(value); err == nil && address.Zone() == "" {
				return address.Unmap().String()
			}
		}
	}
	if address, ok := immediatePeer(r); ok {
		return address.String()
	}
	return "unknown"
}

func requireSecureBoundary(w http.ResponseWriter, r *http.Request) bool {
	if secure(r) {
		return true
	}
	// A cleartext request must never consume credentials or forward a session.
	// Browsers can follow a safe-method redirect; writes must be retried over
	// HTTPS without redirecting a password or other submitted request body.
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "HTTPS is required.", http.StatusUpgradeRequired)
		return false
	}
	host := r.Host
	if hostname, _, err := net.SplitHostPort(host); err == nil {
		host = hostname
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
	}
	target := url.URL{Scheme: "https", Host: host, Path: r.URL.Path, RawPath: r.URL.RawPath, RawQuery: r.URL.RawQuery}
	if host == "" || strings.ContainsAny(host, "/\\\r\n?#@") {
		http.Error(w, "HTTPS is required.", http.StatusUpgradeRequired)
		return false
	}
	http.Redirect(w, r, target.String(), http.StatusMovedPermanently)
	return false
}

// Keep the existing standalone native API boundary: website proxy trust does
// not permit API keys over an HTTP connection to this service.
func nativeTLSOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil {
			http.Error(w, `{"error":{"code":426,"message":"use https"}}`, http.StatusUpgradeRequired)
			return
		}
		next.ServeHTTP(w, r)
	})
}
