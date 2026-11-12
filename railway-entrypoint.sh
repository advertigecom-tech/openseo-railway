#!/bin/sh
# OpenSEO on Railway.
#
# Order of business:
#   1. Give the app a private port and keep Railway's injected $PORT for the
#      gate, because the edge healthcheck dials the injected port.
#   2. Default ALLOWED_HOST to the deployment's own public domain. vite preview
#      refuses any Host header that is not in that list, and an empty list
#      means the public URL answers "Blocked request" on every page.
#   3. Refuse to start without a UI password. In local_noauth mode OpenSEO has
#      no login of its own, so an ungated public deploy is an open admin
#      console holding the deployer's DataForSEO credentials.
#   4. Start the app, then hand PID 1 to nginx.
set -eu

log() { echo "[railway-entrypoint] $*"; }

LISTEN_PORT="${PORT:-8080}"
APP_PORT="${OPENSEO_APP_PORT:-3001}"
DATA_DIR=/app/.wrangler

# The app must not see Railway's injected PORT -- nginx owns it.
export PORT="$APP_PORT"
export OPENSEO_APP_PORT="$APP_PORT"

export ALLOWED_HOST="${ALLOWED_HOST:-${RAILWAY_PUBLIC_DOMAIN:-}}"
if [ -z "$ALLOWED_HOST" ]; then
    log "WARNING: neither ALLOWED_HOST nor RAILWAY_PUBLIC_DOMAIN is set; vite preview will reject requests that arrive with a hostname"
else
    log "allowed host: $ALLOWED_HOST"
fi

# --- volume ---------------------------------------------------------------
# The upstream image sets no USER, and Railway mounts volumes as uid 0, so
# there is usually no ownership repair to do -- but a container that logs EACCES
# and keeps serving looks exactly like one that persists, so prove the mount
# instead of assuming it, and print the uid this actually runs as.
# /app/.wrangler is the whole database: D1 (projects, keywords, rank history,
# the local admin account), KV and R2 all live under it.
mkdir -p "$DATA_DIR"
log "running as $(id -u):$(id -g)"
if : > "$DATA_DIR/.railway-write-test" 2>/dev/null; then
    rm -f "$DATA_DIR/.railway-write-test"
    log "volume $DATA_DIR owner=$(stat -c %u:%g "$DATA_DIR") writable=yes"
else
    log "ERROR: volume $DATA_DIR is NOT writable (owner=$(stat -c %u:%g "$DATA_DIR")). Every project, keyword and rank check will be lost on the next deploy."
fi

# The volume is mounted OVER the directory the image build wrote
# `.wrangler/deploy/config.json` into, and @cloudflare/vite-plugin reads that
# file while `vite preview` resolves its config. Restore it every boot: it is
# build output, not state, so it must track the image rather than the volume.
if [ -d /app/.wrangler-baked ]; then
    cp -a /app/.wrangler-baked/. "$DATA_DIR/" 2>/dev/null \
        && log "restored wrangler build config into the volume" \
        || log "WARNING: could not restore /app/.wrangler-baked into $DATA_DIR"
fi

# Somewhere to write the gate's config and password file. /tmp is not usable on
# Railway ("cannot create /tmp/openseo.htpasswd: Permission denied" on a live
# deploy), so probe rather than assume, and say which one won.
RUNDIR=""
for d in /run/openseo /tmp/openseo "$DATA_DIR/.gate"; do
    if mkdir -p "$d" 2>/dev/null && : > "$d/.w" 2>/dev/null; then
        rm -f "$d/.w"
        RUNDIR="$d"
        break
    fi
done
if [ -z "$RUNDIR" ]; then
    log "ERROR: no writable scratch directory for the gate (tried /run/openseo, /tmp/openseo, $DATA_DIR/.gate)"
    exit 1
fi
log "gate scratch dir: $RUNDIR"

# --- gate credentials -----------------------------------------------------
ADMIN_USER="${OPENSEO_ADMIN_USER:-admin}"
if [ -z "${OPENSEO_ADMIN_PASSWORD:-}" ]; then
    log "ERROR: OPENSEO_ADMIN_PASSWORD is empty."
    log "OpenSEO in Docker mode runs AUTH_MODE=local_noauth: it has no login of its own and treats every"
    log "caller as the admin. Starting without a gate would publish your DataForSEO account to the internet."
    log "Set OPENSEO_ADMIN_PASSWORD in the service variables and redeploy."
    exit 1
fi

HTPASSWD="$RUNDIR/openseo.htpasswd"
if hash="$(openssl passwd -apr1 "$OPENSEO_ADMIN_PASSWORD" 2>/dev/null)" && [ -n "$hash" ]; then
    printf '%s:%s\n' "$ADMIN_USER" "$hash" > "$HTPASSWD"
else
    # Fallback for an openssl without `passwd`. Unsalted, but the password is a
    # 24-character random secret and the file never leaves the container.
    printf '%s:{SHA}%s\n' "$ADMIN_USER" \
        "$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | openssl sha1 -binary | openssl base64)" > "$HTPASSWD"
fi
# When this script runs as root, nginx's master keeps root and its workers drop
# to the user named by the `user` directive, so the file has to be readable by
# THAT user -- a root-only file makes every gated request 500 with
# `open() ... failed (13: Permission denied)` while the cookie path keeps
# working, which reads as an app fault. When it runs as anyone else there is no
# privilege drop and the workers inherit this uid.
if [ "$(id -u)" = "0" ] && chown www-data:www-data "$HTPASSWD" 2>/dev/null; then
    chmod 400 "$HTPASSWD"
    OPENSEO_NGINX_USER="user www-data;"
else
    chmod 400 "$HTPASSWD"
    OPENSEO_NGINX_USER=""
fi
export OPENSEO_NGINX_USER OPENSEO_RUNDIR="$RUNDIR"

# Browsers do not reliably attach basic-auth credentials to a WebSocket
# handshake, and OpenSEO's in-app agent (SAM) talks over /agents/ via
# WebSocket. Cookies are always sent, so the gate hands out a cookie once the
# password has been accepted and takes either afterwards.
OPENSEO_GATE_COOKIE="$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | openssl sha256 -hex 2>/dev/null | awk '{print $NF}')"
[ -n "$OPENSEO_GATE_COOKIE" ] || OPENSEO_GATE_COOKIE="$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)"
export OPENSEO_GATE_COOKIE

# An empty token must close /mcp, never open it: an unset variable is the one
# case where a match-anything value would hand the endpoint to the internet.
if [ -z "${OPENSEO_MCP_TOKEN:-}" ]; then
    log "OPENSEO_MCP_TOKEN is unset -- /mcp is closed. Set it to use OpenSEO's MCP server from an agent."
    OPENSEO_MCP_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
export OPENSEO_MCP_TOKEN

# --- app ------------------------------------------------------------------
# Prepare API secrets before starting OpenSEO
SECRET_FILE="/app/dist/server/.dev.vars"

mkdir -p "$(dirname "$SECRET_FILE")"
touch "$SECRET_FILE"
chmod 600 "$SECRET_FILE"

for KEY_NAME in DATAFORSEO_API_KEY OPENROUTER_API_KEY; do
  KEY_VALUE="${!KEY_NAME:-}"

  if [ -n "$KEY_VALUE" ]; then
    sed -i "/^${KEY_NAME}=/d" "$SECRET_FILE"
    printf '%s="%s"\n' "$KEY_NAME" "$KEY_VALUE" >> "$SECRET_FILE"
    echo "$KEY_NAME configured"
  fi
done
log "starting OpenSEO on 127.0.0.1:${APP_PORT} (gate on ${LISTEN_PORT})"
sh /app/docker-entrypoint.sh &
APP_PID=$!

i=0
while [ "$i" -lt 300 ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "OpenSEO exited during startup"
        wait "$APP_PID" || exit $?
        exit 1
    fi
    if node -e "fetch('http://127.0.0.1:'+process.env.OPENSEO_APP_PORT+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
        log "OpenSEO answered /api/health after ${i}s"
        break
    fi
    sleep 1
    i=$((i + 1))
done

# --- gate -----------------------------------------------------------------
export PORT="$LISTEN_PORT"
envsubst '${PORT} ${OPENSEO_APP_PORT} ${OPENSEO_MAX_BODY_SIZE} ${OPENSEO_RATE} ${OPENSEO_RATE_BURST} ${OPENSEO_MCP_TOKEN} ${OPENSEO_GATE_COOKIE} ${OPENSEO_NGINX_USER} ${OPENSEO_RUNDIR}' \
    < /etc/openseo/nginx.conf.template > "$RUNDIR/nginx.conf"
log "gate listening on ${LISTEN_PORT}: UI behind ${ADMIN_USER}:<OPENSEO_ADMIN_PASSWORD>, /mcp behind bearer OPENSEO_MCP_TOKEN, /api/health open for the Railway healthcheck"

# nginx becomes PID 1 below. If the app dies the container has to die with it,
# or the healthcheck keeps passing against a gate with nothing behind it.
(
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 5; done
    log "OpenSEO exited, stopping the gate"
    kill 1 2>/dev/null || true
) &

exec nginx -c "$RUNDIR/nginx.conf" -g 'daemon off;'
