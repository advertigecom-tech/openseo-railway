# openseo-railway

Fully Fixed DataForSeo & Openrouter (Working) 12/NOV/2026

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/openseo-v013-or-semrush-alternative-whos?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [OpenSEO template](https://railway.com/deploy/openseo-v013-or-semrush-alternative-whos?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for running [OpenSEO](https://github.com/every-app/open-seo) — an open-source
alternative to Semrush and Ahrefs — on [Railway](https://railway.com).

`ghcr.io/bon5co/openseo-railway:latest` — built from `ghcr.io/every-app/open-seo:v0.1.3`.

The upstream application is unmodified. What this image adds is the two things the stock
self-host image cannot do for itself on a platform that recreates the container on every
deploy and puts the result on a public URL.

Both claims below were reproduced against the upstream image, and the first one against the
category leader's own gateway source.

## 1. `POST /mcp` has no authentication, and the leading listing's password gate exempts it

Docker self-hosting runs `AUTH_MODE=local_noauth`. Upstream is explicit that this mode has no
auth and must sit behind something. Two Railway listings publish it on a public domain:

- `openseo-semrush-ahrefs-alternative` — the app alone, with a public domain and no gate at
  all. Every path is open, including the MCP endpoint below.
- `openseo` (category leader) — the app privately, plus a password gateway service built from
  source out of `Lukem121/openseo`. The browser UI is genuinely gated.

The leader's gateway deliberately forwards `/mcp`, `/.well-known/*`, `/api/auth/oauth2/*` and
`/api/oauth/consent` without the cookie, on the reasoning in its own comment: *"MCP clients
(Cursor, Claude, Codex) cannot present the gate cookie … Clients discover and authorize
against OpenSEO."*

They do not, because in `local_noauth` OpenSEO performs no authorization on that route.
`src/server.ts` routes `/mcp` to `handleSelfHostedOpenSeoMcpRequest`, which calls
`resolveLocalNoAuthContext()` — the injected local admin — for every caller
(`src/server/mcp/transport.ts`). Reproduced end to end against `v0.1.3` behind that exact
gateway (`SITE_PASSWORD` set, upstream private):

```
GET  /             -> 401   (login page: the gate works)
POST /mcp          -> 200   whoami: local-admin (admin@localhost), org delegated-local-admin
POST /mcp          -> 200   list_projects / create_project succeed anonymously
```

24 tools are exposed that way, including `research_keywords`, `get_backlinks_profile` and
`get_serp_results` — every one of them spends the deployer's **paid DataForSEO credits**, and
`create_project` writes to their workspace.

This image gates the whole surface in one container:

| path | who gets in |
|---|---|
| `/api/health` | open — Railway's healthcheck is unauthenticated, and upstream's endpoint reports check statuses, never values |
| `/mcp` | `Authorization: Bearer $OPENSEO_MCP_TOKEN` only |
| everything else | HTTP basic auth, `$OPENSEO_ADMIN_USER` / `$OPENSEO_ADMIN_PASSWORD` |

Agents keep working: a bearer token is something an MCP client *can* present, which a cookie
is not. The first accepted password also sets a cookie, because browsers do not reliably
attach basic-auth credentials to a WebSocket handshake and OpenSEO's in-app agent talks over
`/agents/` via WebSocket.

With `OPENSEO_ADMIN_PASSWORD` empty the container **refuses to start** rather than serving an
ungated admin console.

## 2. The stock image rebuilds the whole app on every container start

`docker-entrypoint.sh` runs `pnpm run build` at container start and skips it only when
`dist/.openseo-build-env` matches a fingerprint of the build-relevant environment. `dist` is
in the container filesystem, never on the volume, so on Railway — where a deploy or a restart
is always a fresh container — the build runs every single time.

Measured on `v0.1.3`, 5 vCPU / 8 GB, identical env, volume already migrated (the redeploy
case):

| image | container start → `/api/health` 200 | peak memory |
|---|---:|---:|
| `ghcr.io/every-app/open-seo:v0.1.3` | **105 s** | 3.16 GiB |
| this image | **8 s** | 0.63 GiB |

With an empty volume it is 119 s against 20 s.

The build is baked at image build time together with the fingerprint upstream's entrypoint
looks for, so the container start logs `Reusing existing build (build-relevant env
unchanged).` The mechanism is preserved, not disabled: a deployer who changes `AUTH_MODE` or
any `VITE_*` value still gets a correct rebuild at boot.

## Configuration

Baked in (so they never appear as blank required fields on a Railway template form):
`AUTH_MODE=local_noauth`, `CLOUDFLARE_INCLUDE_PROCESS_ENV=true`, `VITE_SHOW_DEVTOOLS=false`,
`OPENSEO_APP_PORT=3001`, `OPENSEO_ADMIN_USER=admin`, `OPENSEO_MAX_BODY_SIZE=25m`,
`OPENSEO_RATE=20r/s`, `OPENSEO_RATE_BURST=60`.

Set at deploy time:

| variable | purpose |
|---|---|
| `OPENSEO_ADMIN_PASSWORD` | UI password. Empty = the container refuses to boot. |
| `OPENSEO_MCP_TOKEN` | Bearer token for `/mcp`. Empty = `/mcp` is closed. |
| `DATAFORSEO_API_KEY` | base64 of your DataForSEO `login:password`. The app boots without it and reports it as missing on `/api/health`. |
| `BETTER_AUTH_SECRET` | encrypts stored Google Search Console OAuth tokens (optional feature). |
| `ALLOWED_HOST` | defaults to `$RAILWAY_PUBLIC_DOMAIN`; vite preview rejects any other hostname. |

The volume belongs at **`/app/.wrangler`** — D1, KV and R2 state, i.e. every project, keyword,
rank-tracking history and the local admin workspace.

The rate limiter keys on the first address of `X-Forwarded-For`, not the whole header: Railway
replaces the inbound header, but its own edge hop rotates between requests, so a key built
from the whole value gives every retry a fresh bucket.
