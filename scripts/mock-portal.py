#!/usr/bin/env python3
"""Tiny mock of the Pinner portal auth/account API, used only for local image
verification (compose/wordpress.local.yaml). It implements just the two
endpoints the baked-in workspace-init CLI needs:

    POST /api/auth/key  -> 200 {"token": <login-purpose JWT>}
                           (accepts the raw API key verbatim on Authorization)
    GET  /api/account   -> 200 {"email": <owner email>, ...}
                           (accepts ONLY "Bearer <login-purpose JWT>")

This mirrors the real portal contract that workspace-init relies on: a raw
API-key token is rejected (401) on /api/account; only the login-purpose JWT
obtained by exchanging the key through POST /api/auth/key works there. The
values here must match the PORTAL_API_KEY / expected email used by the compose
stack and verify-wordpress.sh.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

API_KEY = "local-portal-api-key"
LOGIN_JWT = "login-purpose.jwt.token"
OWNER_EMAIL = "owner@example.test"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep quiet; never log credentials
        pass

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path == "/api/auth/key":
            if self.headers.get("Authorization") != API_KEY:
                self._send(401, {"error": "bad api key"})
                return
            self._send(200, {"token": LOGIN_JWT})
            return
        self._send(404, {"error": "not found"})

    def do_GET(self) -> None:
        if self.path == "/api/account":
            if self.headers.get("Authorization") != "Bearer " + LOGIN_JWT:
                self._send(401, {"error": "unauthorized"})
                return
            self._send(200, {
                "email": OWNER_EMAIL,
                "first_name": "Owner",
                "last_name": "Example",
                "id": 1,
            })
            return
        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
