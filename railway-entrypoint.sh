
#!/bin/sh
# OpenSEO on Railway
# Supports DataForSEO + OpenRouter
# Compatible with POSIX sh

set -eu

log() {
    echo "[railway-entrypoint] $*"
}

LISTEN_PORT="${PORT:-8080}"
APP_PORT="${OPENSEO_APP_PORT:-3001}"
DATA_DIR="/app/.wrangler"

# The OpenSEO app uses its own private port.
# Nginx handles Railway's public port.
export PORT="$APP_PORT"
export OPENSEO_APP_PORT="$APP_PORT"

# Configure allowed hostname
export ALLOWED_HOST="${ALLOWED_HOST:-${RAILWAY_PUBLIC_DOMAIN:-}}"

if [ -z "$ALLOWED_HOST" ]; then
    log "WARNING: ALLOWED_HOST is not configured"
else
    log "Allowed host: $ALLOWED_HOST"
fi

# --------------------------------------------------
# PERSISTENT VOLUME
# --------------------------------------------------

mkdir -p "$DATA_DIR"

log "Running as $(id -u):$(id -g)"

if : > "$DATA_DIR/.railway-write-test" 2>/dev/null; then
    rm -f "$DATA_DIR/.railway-write-test"
    log "Persistent volume is writable"
else
    log "WARNING: Persistent volume is not writable"
fi

# Restore Wrangler configuration from Docker image
if [ -d /app/.wrangler-baked ]; then
    if cp -a /app/.wrangler-baked/. "$DATA_DIR/" 2>/dev/null; then
        log "Wrangler build config restored"
    else
        log "WARNING: Wrangler config restore failed"
    fi
fi

# --------------------------------------------------
# NGINX RUNTIME DIRECTORY
# --------------------------------------------------

RUNDIR=""

for d in /run/openseo /tmp/openseo "$DATA_DIR/.gate"; do
    if mkdir -p "$d" 2>/dev/null && : > "$d/.w" 2>/dev/null; then
        rm -f "$d/.w"
        RUNDIR="$d"
        break
    fi
done

if [ -z "$RUNDIR" ]; then
    log "ERROR: No writable directory for Nginx"
    exit 1
fi

log "Gate scratch directory: $RUNDIR"

# --------------------------------------------------
# ADMIN AUTHENTICATION
# --------------------------------------------------

ADMIN_USER="${OPENSEO_ADMIN_USER:-admin}"

if [ -z "${OPENSEO_ADMIN_PASSWORD:-}" ]; then
    log "ERROR: OPENSEO_ADMIN_PASSWORD is missing"
    exit 1
fi

HTPASSWD="$RUNDIR/openseo.htpasswd"

if hash="$(openssl passwd -apr1 "$OPENSEO_ADMIN_PASSWORD" 2>/dev/null)" && [ -n "$hash" ]; then
    printf '%s:%s\n' "$ADMIN_USER" "$hash" > "$HTPASSWD"
else
    printf '%s:{SHA}%s\n' "$ADMIN_USER" \
        "$(printf '%s' "$OPENSEO_ADMIN_PASSWORD" | openssl sha1 -binary | openssl base64)" \
        > "$HTPASSWD"
fi

if [ "$(id -u)" = "0" ] && chown www-data:www-data "$HTPASSWD" 2>/dev/null; then
    chmod 400 "$HTPASSWD"
    OPENSEO_NGINX_USER="user www-data;"
else
    chmod 400 "$HTPASSWD"
    OPENSEO_NGINX_USER=""
fi

export OPENSEO_NGINX_USER
export OPENSEO_RUNDIR="$RUNDIR"

# --------------------------------------------------
# AUTH COOKIE
# --------------------------------------------------

OPENSEO_GATE_COOKIE="$(
    printf '%s' "$OPENSEO_ADMIN_PASSWORD" |
    openssl sha256 -hex 2>/dev/null |
    awk '{print $NF}'
)"

if [ -z "$OPENSEO_GATE_COOKIE" ]; then
    OPENSEO_GATE_COOKIE="$(
        printf '%s' "$OPENSEO_ADMIN_PASSWORD" |
        sha256sum |
        cut -d' ' -f1
    )"
fi

export OPENSEO_GATE_COOKIE

# --------------------------------------------------
# MCP AUTHENTICATION
# --------------------------------------------------

if [ -z "${OPENSEO_MCP_TOKEN:-}" ]; then
    log "MCP token not configured; generating temporary token"

    OPENSEO_MCP_TOKEN="$(
        head -c 32 /dev/urandom |
        od -An -tx1 |
        tr -d ' \n'
    )"
fi

export OPENSEO_MCP_TOKEN

# --------------------------------------------------
# CLOUDFLARE WORKER API SECRETS
# --------------------------------------------------

# The prebuilt Vite Worker loads this file
# when its preview server starts.

SECRET_FILE="/app/dist/server/.dev.vars"

mkdir -p "$(dirname "$SECRET_FILE")"
touch "$SECRET_FILE"
chmod 600 "$SECRET_FILE"

# Remove previous definitions to avoid duplicates.
sed -i '/^DATAFORSEO_API_KEY=/d' "$SECRET_FILE"
sed -i '/^OPENROUTER_API_KEY=/d' "$SECRET_FILE"

# DataForSEO
if [ -n "${DATAFORSEO_API_KEY:-}" ]; then

    printf 'DATAFORSEO_API_KEY="%s"\n' \
        "$DATAFORSEO_API_KEY" >> "$SECRET_FILE"

    log "DataForSEO secret configured"

else
    log "WARNING: DATAFORSEO_API_KEY not set"
fi

# OpenRouter
if [ -n "${OPENROUTER_API_KEY:-}" ]; then

    printf 'OPENROUTER_API_KEY="%s"\n' \
        "$OPENROUTER_API_KEY" >> "$SECRET_FILE"

    log "OpenRouter secret configured"

else
    log "WARNING: OPENROUTER_API_KEY not set"
fi

chmod 600 "$SECRET_FILE"

# Make process variables available to
# Cloudflare's local Worker environment.
export CLOUDFLARE_INCLUDE_PROCESS_ENV=true

log "Worker secrets prepared before app startup"

# --------------------------------------------------
# START OPENSEO
# --------------------------------------------------

log "Starting OpenSEO on port $APP_PORT"

sh /app/docker-entrypoint.sh &

APP_PID=$!

# Wait for the app to become healthy.
i=0

while [ "$i" -lt 300 ]; do

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "ERROR: OpenSEO exited during startup"
        wait "$APP_PID" || exit $?
        exit 1
    fi

    if node -e "fetch('http://127.0.0.1:'+process.env.OPENSEO_APP_PORT+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
        log "OpenSEO health check passed after ${i}s"
        break
    fi

    sleep 1
    i=$((i + 1))
done

if [ "$i" -ge 300 ]; then
    log "ERROR: OpenSEO health check timed out"
    exit 1
fi

# --------------------------------------------------
# START NGINX GATE
# --------------------------------------------------

export PORT="$LISTEN_PORT"

envsubst '${PORT} ${OPENSEO_APP_PORT} ${OPENSEO_MAX_BODY_SIZE} ${OPENSEO_RATE} ${OPENSEO_RATE_BURST} ${OPENSEO_MCP_TOKEN} ${OPENSEO_GATE_COOKIE} ${OPENSEO_NGINX_USER} ${OPENSEO_RUNDIR}' \
    < /etc/openseo/nginx.conf.template \
    > "$RUNDIR/nginx.conf"

log "Nginx configured on port $LISTEN_PORT"

# Stop Nginx if the application exits.
(
    while kill -0 "$APP_PID" 2>/dev/null; do
        sleep 5
    done

    log "OpenSEO stopped. Shutting down gateway."
    kill 1 2>/dev/null || true
) &

log "OpenSEO gateway starting"

exec nginx -c "$RUNDIR/nginx.conf" -g 'daemon off;'
