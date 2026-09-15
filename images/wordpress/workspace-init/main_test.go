package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	fakeAPIKey = "test-api-key-123"
	fakeJWT    = "login-purpose.jwt.token"
	fakeEmail  = "owner@example.test"
)

// fakePortal simulates the dashboard auth/account API. It enforces the two key
// properties the real portal guarantees:
//   - POST /api/auth/key accepts the raw API-key token (verbatim Authorization)
//     and returns a login-purpose JWT.
//   - GET /api/account ONLY accepts the login-purpose JWT (Bearer prefix); the
//     raw API-key token must be rejected there. This is exactly why
//     workspace-init must exchange the key before calling GetAccount.
func fakePortal() *httptest.Server {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/auth/key", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.Header.Get("Authorization") != fakeAPIKey {
			http.Error(w, `{"error":"bad api key"}`, http.StatusUnauthorized)
			return
		}
		writeJSON(w, map[string]string{"token": fakeJWT})
	})

	mux.HandleFunc("/api/account", func(w http.ResponseWriter, r *http.Request) {
		// Account routes must never accept the raw API-key token.
		if r.Header.Get("Authorization") != "Bearer "+fakeJWT {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		writeJSON(w, map[string]string{
			"email":      fakeEmail,
			"first_name": "Owner",
			"last_name":  "Example",
		})
	})

	return httptest.NewServer(mux)
}

func TestFetchEmailExchangeFlow(t *testing.T) {
	srv := fakePortal()
	defer srv.Close()

	t.Setenv(envAPIURL, srv.URL)
	t.Setenv(envAPIKey, fakeAPIKey)

	email, err := fetchEmail(context.Background())
	if err != nil {
		t.Fatalf("fetchEmail returned error: %v", err)
	}
	if email != fakeEmail {
		t.Fatalf("email = %q, want %q", email, fakeEmail)
	}
}

func TestFetchEmailRejectsRawKeyOnAccountRoutes(t *testing.T) {
	// This server rejects the API key on /api/account (the real portal's
	// behaviour), so a naive implementation that passed the raw key straight to
	// account routes would fail. Our implementation always exchanges through
	// /api/auth/key and must therefore succeed.
	var accountCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/auth/key":
			if r.Header.Get("Authorization") != fakeAPIKey {
				http.Error(w, "bad key", http.StatusUnauthorized)
				return
			}
			writeJSON(w, map[string]string{"token": fakeJWT})
		case "/api/account":
			accountCalls++
			if r.Header.Get("Authorization") != "Bearer "+fakeJWT {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, map[string]string{"email": fakeEmail})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	t.Setenv(envAPIURL, srv.URL)
	t.Setenv(envAPIKey, fakeAPIKey)

	email, err := fetchEmail(context.Background())
	if err != nil {
		t.Fatalf("fetchEmail returned error: %v", err)
	}
	if email != fakeEmail {
		t.Fatalf("email = %q, want %q", email, fakeEmail)
	}
	if accountCalls == 0 {
		t.Fatal("expected at least one call to account route")
	}
}

func TestFetchEmailMissingEnv(t *testing.T) {
	t.Setenv(envAPIURL, "")
	_, err := fetchEmail(context.Background())
	if err == nil {
		t.Fatal("expected error when PORTAL_API_URL is missing")
	}
	if !strings.Contains(err.Error(), envAPIURL) {
		t.Fatalf("error %q should identify missing var %s", err, envAPIURL)
	}
}

func TestFetchEmailBadCredentials(t *testing.T) {
	srv := fakePortal()
	defer srv.Close()

	t.Setenv(envAPIURL, srv.URL)
	t.Setenv(envAPIKey, "wrong-key")

	_, err := fetchEmail(context.Background())
	if err == nil {
		t.Fatal("expected error for bad api key")
	}
	// The error must never leak the credential/JWT.
	for _, secret := range []string{fakeAPIKey, fakeJWT, "wrong-key"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error leaked secret %q: %v", secret, err)
		}
	}
}

// writeJSON sets the JSON content type the oapi-codegen client expects when it
// decodes a JSON200 body, then encodes v.
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
