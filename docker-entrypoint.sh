#!/bin/sh
# Container entrypoint. Runs as root so it can fix ownership of a bind-mounted
# /data (Docker may create it as root on the host), then drops privileges via
# gosu and execs the real command as the unprivileged zed2api user (uid 10001).
set -e

# Ensure the runtime data dir is writable by the app user. Best-effort: if /data
# is read-only or chown is unavailable (some rootless/readonly setups), just
# proceed — the app will surface a clear write error if it truly cannot persist.
chown -R 10001:10001 /data 2>/dev/null || chmod -R u+rwX /data 2>/dev/null || true

# Drop to the unprivileged user and run whatever CMD passed through.
exec gosu zed2api:zed2api "$@"
