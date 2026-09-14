#!/bin/sh
# pinner-auth-setup.sh — validate and prepare workspace HTTP Basic Auth.
#
# Sourced by docker-entrypoint.sh BEFORE the privilege drop (after any child
# PINNER_INIT hook). It validates the WORKSPACE_AUTH_USERNAME /
# WORKSPACE_AUTH_PASSWORD secret environment variables that the Pinner portal
# injects (portal-plugin-ipfs PR #1031), derives a Caddy Basic-Auth bcrypt hash
# from the password, and exports WORKSPACE_AUTH_USERNAME / WORKSPACE_AUTH_HASH
# for the Caddyfile's `basicauth {$WORKSPACE_AUTH_USERNAME} {$WORKSPACE_AUTH_HASH}`
# placeholder.
#
# Fail-closed: if either secret is missing/empty the container REFUSES to start
# rather than serve the workspace publicly unauthenticated. This matches the
# portal's environment builder, which fails closed
# (ErrProxyCredentialsUnavailable, internal/service/workspace/application.go)
# when the workspace row lacks credentials, so a provisioned workspace always
# has both variables present.
#
# Secret hygiene: the plaintext password is never echoed or written to disk.
# It is fed to `caddy hash-password` on stdin (not argv, so it never appears in
# a process listing visible via /proc), and only the derived bcrypt hash is
# carried forward — transiently, in the process environment, never in a file.
# Success only sets env vars; nothing is logged containing the credential or
# the hash.
#
# Rotation: the portal applies rotated credentials as a secret-env upsert of
# the two WORKSPACE_AUTH_* vars followed by an application redeploy, so a
# container (re)start re-runs this derivation from the current environment and
# the new credential takes effect on redeploy — no restartless re-read needed.

username="${WORKSPACE_AUTH_USERNAME:-}"
password="${WORKSPACE_AUTH_PASSWORD:-}"

if [ -z "$username" ] || [ -z "$password" ]; then
    echo "pinner: WORKSPACE_AUTH_USERNAME and WORKSPACE_AUTH_PASSWORD are both required; refusing to start unauthenticated" >&2
    exit 1
fi

# Derive a Caddy Basic-Auth hash (bcrypt) from the password, feeding it on
# stdin so the plaintext never appears in process argv. `caddy hash-password`
# needs a trailing newline on stdin (no-newline input makes it error with EOF);
# the password itself never contains one (portal credentials are lowercase
# alnum). Command substitution strips the hasher's own trailing newline, so
# auth_hash holds exactly the hash. Fail closed if hashing unexpectedly fails.
auth_hash="$(printf '%s\n' "$password" | /usr/bin/caddy hash-password 2>/dev/null || true)"
if [ -z "$auth_hash" ]; then
    echo "pinner: failed to derive workspace auth hash; refusing to start" >&2
    exit 1
fi

export WORKSPACE_AUTH_USERNAME="$username"
export WORKSPACE_AUTH_HASH="$auth_hash"
