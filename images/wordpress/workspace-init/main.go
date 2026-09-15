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
	"os"
	"strings"
	"time"

	sdk "go.lumeweb.com/portal-sdk"
)

const (
	envAPIURL = "PORTAL_API_URL"
	envAPIKey = "PORTAL_API_KEY"
)

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
