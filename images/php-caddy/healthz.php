<?php
/**
 * Local loopback-exempt health probe.
 *
 * Public (non-loopback) document/health access is gated at the Caddy layer by
 * HTTP Basic Auth derived from the WORKSPACE_AUTH_* secret environment
 * variables (portal-plugin-ipfs PR #1031). This endpoint is used by the
 * container's own Docker/Coolify health check against localhost, which Caddy
 * exempts via its remote_ip loopback matcher, so it is reached here without
 * credentials. Returning 200 from PHP proves the PHP-FPM backend is processing
 * requests (not just that Caddy can serve a static file).
 */
http_response_code(200);
header('Content-Type: text/plain');
echo "ok\n";
