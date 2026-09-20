// Command workspace-init is a tiny helper baked into the Pinner WordPress
// image. It exchanges the portal's API key for a short-lived login-purpose JWT
// and prints the owning account's email address (the workspace owner's email)
// to stdout. The WordPress init hook (wp-init.sh) uses that email as the admin
// address during automatic first-boot install.
//
// Security properties:
//   - Reads secrets only from the environment (PORTAL_API_URL / PORTAL_API_KEY);
//     it never takes them from argv.
//   - Never prints the API key, the JWT, or any credential — stdout carries the
//     email only; all errors go to stderr with no secret material.
//   - A raw API-key token is NOT accepted on account routes by the dashboard,
//     so we always exchange it via POST /api/auth/key (LoginWithAPIKey) to get
//     a login-purpose JWT, SetAuthToken it, and only then call GetAccount.
package main

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	sdk "go.lumeweb.com/portal-sdk"
)

const (
	envAPIURL = "PORTAL_API_URL"
	envAPIKey = "PORTAL_API_KEY"

	// dashboardAPISubdomain is the host subdomain behind which the dashboard
	// API's key-exchange routes (POST /api/auth/key, GET /api/account) are
	// routed. It mirrors the value pinned in portal-plugin-ipfs; the dashboard
	// core package does not export it.
	dashboardAPISubdomain = "account"
)

// deriveDashboardAPIURL normalizes the injected PORTAL_API_URL so requests
// always target the dashboard API host. Older portal deployments inject the
// bare core domain (e.g. https://pinner.xyz) or this plugin's subdomain
// (e.g. https://ipfs.pinner.xyz), but the key-exchange routes only exist
// behind the dashboard's host router (account.<core domain>); hitting any
// other host yields 405 and skips automatic install. Loopback/IP hosts and
// hosts already rooted at the dashboard subdomain are returned unchanged.
// An unparseable URL is returned as-is; the failure then surfaces from the
// client with full context.
func deriveDashboardAPIURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return rawURL
	}

	host := strings.ToLower(u.Hostname())
	// IPs and dotless hosts (e.g. "localhost") have no derivable core domain;
	// treat them as already-final dev/test targets.
	if net.ParseIP(host) != nil || !strings.Contains(host, ".") {
		return rawURL
	}

	labels := strings.Split(host, ".")
	if labels[0] == dashboardAPISubdomain {
		return rawURL
	}

	// Drop any leftmost plugin subdomain so an apex URL and a subdomain URL
	// both reduce to the core domain, then prepend the dashboard subdomain:
	// pinner.xyz / ipfs.pinner.xyz -> account.pinner.xyz.
	core := strings.Join(labels[len(labels)-2:], ".")

	schemeHost := dashboardAPISubdomain + "." + core
	if port := u.Port(); port != "" {
		schemeHost = net.JoinHostPort(schemeHost, port)
	}
	u.Host = schemeHost
	return u.String()
}

func main() {
	email, err := fetchEmail(context.Background())
	if err != nil {
		fmt.Fprintln(os.Stderr, "workspace-init:", err)
		os.Exit(1)
	}
	// The email is the only value on stdout. Never print the JWT or API key.
	fmt.Println(email)
}

// fetchEmail performs the API-key -> login-purpose JWT exchange and returns the
// owner email. It is separated from main so unit tests can drive it with a
// caller-supplied context and a fake portal.
func fetchEmail(ctx context.Context) (string, error) {
	apiURL := strings.TrimRight(os.Getenv(envAPIURL), "/")
	apiKey := os.Getenv(envAPIKey)

	if apiURL == "" {
		return "", fmt.Errorf("%s is required", envAPIURL)
	}
	if apiKey == "" {
		return "", fmt.Errorf("%s is required", envAPIKey)
	}

	// Older portal deployments inject the bare core domain or the plugin's own
	// subdomain as PORTAL_API_URL; the key-exchange routes only exist behind
	// the dashboard API's host, so point the client there.
	apiURL = deriveDashboardAPIURL(apiURL)

	// Bound the whole portal round-trip so a hung/unreachable portal cannot
	// stall the container's init forever; wp-init treats a failure here as
	// "email unavailable" and safely skips automatic install.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	client := sdk.NewClient(sdk.WithEndpoint(apiURL))

	// Dashboard API-key exchange: POST /api/auth/key -> login-purpose JWT.
	// A raw API-key token is rejected by account routes, so we must exchange it.
	jwt, err := client.LoginWithAPIKey(ctx, apiKey)
	if err != nil {
		return "", fmt.Errorf("portal api-key exchange failed (%s): %w", envAPIKey, err)
	}
	client.SetAuthToken(jwt)

	info, err := client.GetAccount(ctx)
	if err != nil {
		return "", fmt.Errorf("portal account lookup failed: %w", err)
	}
	if strings.TrimSpace(info.Email) == "" {
		return "", fmt.Errorf("portal account response contained no email")
	}

	return strings.TrimSpace(info.Email), nil
}
