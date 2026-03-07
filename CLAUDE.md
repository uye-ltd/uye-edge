# CLAUDE.md — uye-edge project knowledge base

This file is the authoritative reference for AI-assisted work in this repository.
Read it fully before making any changes.

---

## Project purpose

`uye-edge` is a **Dockerized NGINX edge API gateway** for the UYE platform.
It is the outermost network layer: it handles TLS termination, reverse-proxying,
rate limiting, compression, and security headers. It contains **no business logic**.

The only upstream this gateway talks to is the internal Go Gateway (`uye-gate`),
which owns session → JWT conversion and authorization. That service lives in a
separate repository and is referenced here only as an upstream target.

```
Browser  ──HTTPS──▶  uye-edge (this repo)  ──HTTP──▶  Go Gateway  ──▶  Microservices
```

---

## Strict scope boundary

- NGINX handles: TLS, routing, rate limiting, compression, access logging, security headers, health checks.
- NGINX does NOT handle: authentication, authorization, session management, JWT, business routing rules.
- Never add business logic, auth checks, or Lua scripts to this repo.
- Never add application-level services (databases, caches, app servers) to docker-compose.yml.

---

## Repository layout

```
uye-edge/
├── Dockerfile
├── docker-compose.yml          # Production (services: nginx, certbot*, nginx-exporter*, go-gateway*)
├── docker-compose.dev.yml      # Dev overrides — self-signed cert, stub upstream, hot-reload mounts
├── .env.example                # Canonical list of all env vars with defaults and comments
├── .env.dev                    # Dev defaults — relaxed rate limits, localhost domain, self-signed TLS
├── .gitignore                  # Excludes .env, .env.local, certs/dev/, certbot/
├── .dockerignore
├── nginx/
│   ├── nginx.conf              # Main config — worker settings, client limits, include order
│   ├── conf.d/                 # Static modular configs copied into image at build time
│   │   ├── logging.conf        # JSON log format definition + access_log / error_log directives
│   │   ├── gzip.conf           # Gzip compression for all relevant MIME types
│   │   ├── security.conf       # UA filter map, method filter map, proxy_max_temp_file_size
│   │   ├── ssl-params.conf     # TLS protocols, ciphers, session cache, OCSP stapling
│   │   └── proxy-params.conf   # Proxy headers, HTTP/1.1 keepalive, buffering, retry policy
│   └── templates/              # envsubst templates — processed to conf.d/ at container startup
│       ├── rate-limit.conf.template     → conf.d/rate-limit.conf
│       ├── upstream.conf.template       → conf.d/upstream.conf
│       ├── http-server.conf.template    → conf.d/http-server.conf
│       └── https-server.conf.template  → conf.d/https-server.conf
├── scripts/
│   ├── generate-self-signed.sh # Dev: create certs/dev/selfsigned.{crt,key} via openssl
│   ├── certbot-renew.sh        # Production: renew certs + nginx -s reload (for cron)
│   └── healthcheck.sh          # Manual: curl http://localhost/healthz
├── dev/
│   └── go-gateway-stub.conf    # nginx config for the stub Go Gateway container in dev
├── certbot/                    # Placeholder dir — actual data lives in Docker volumes
└── certs/                      # Dev self-signed certs (gitignored, generated locally)
    └── dev/
        ├── selfsigned.crt
        └── selfsigned.key
```

---

## Configuration templating — critical mechanism

The official `nginx:1.27-alpine` Docker image includes
`/docker-entrypoint.d/20-envsubst-on-templates.sh`.
At container startup, **before nginx launches**, this script:

1. Reads every `*.template` file from `/etc/nginx/templates/`.
2. Runs `envsubst` against the process environment.
3. Writes the result to `/etc/nginx/conf.d/<filename-without-.template>`.

**Consequences:**
- Files in `nginx/templates/` are NOT valid nginx config on their own; they are text templates.
- The final nginx config exists only inside the running container at `/etc/nginx/conf.d/`.
- To validate a template locally, set env vars and run `envsubst < template > /tmp/out && nginx -t -c /tmp/out`.
- `nginx.conf` itself is NOT processed by envsubst. It contains only static directives.

### envsubst variable collision risk

`envsubst` substitutes ALL environment variables present in the process.
Nginx variables (`$host`, `$uri`, `$remote_addr`, `$scheme`, `$request_uri`, etc.)
use lowercase names. Container env vars in this project use uppercase (`NGINX_*`).
These do NOT collide — lowercase nginx variables are safe from substitution.

**Do not** name env vars with lowercase or mixed-case names that match nginx built-in
variables (e.g. `host`, `scheme`, `uri`). This would cause substitution corruption.

---

## Environment variables reference

All variables must be present in the environment when the container starts.
Missing variables cause `envsubst` to silently produce empty strings, which will
fail nginx config validation (`nginx -t`).

| Variable | Format | Example | Notes |
|---|---|---|---|
| `NGINX_DOMAIN` | hostname | `api.example.com` | Used as `server_name` in both server blocks, and in default cert paths |
| `CERTBOT_EMAIL` | email | `ops@example.com` | Used only by `certbot` profile |
| `NGINX_SSL_CERT_PATH` | absolute path | `/etc/nginx/ssl/live/api.example.com/fullchain.pem` | Must exist inside container at runtime |
| `NGINX_SSL_KEY_PATH` | absolute path | `/etc/nginx/ssl/live/api.example.com/privkey.pem` | Must exist inside container at runtime |
| `NGINX_SSL_CHAIN_PATH` | absolute path | `/etc/nginx/ssl/live/api.example.com/chain.pem` | Required for OCSP stapling (`ssl_trusted_certificate`) |
| `NGINX_UPSTREAM_HOST` | hostname/IP | `go-gateway` | Docker service name or external hostname |
| `NGINX_UPSTREAM_PORT` | port | `8080` | Port the Go Gateway listens on |
| `NGINX_LB_ALGORITHM` | nginx directive or empty | `least_conn;` | **Must include the trailing semicolon**, or be empty for round-robin. See below. |
| `NGINX_RATE_LIMIT_RATE` | nginx rate | `100r/m` | `limit_req_zone` rate for `api_per_ip` zone |
| `NGINX_RATE_LIMIT_BURST` | integer | `20` | `limit_req burst=` value for `/api/` |
| `NGINX_RATE_LIMIT_AUTH_RATE` | nginx rate | `10r/m` | Rate for `auth` zone |
| `NGINX_RATE_LIMIT_AUTH_BURST` | integer | `5` | Burst for `/api/auth/` |
| `NGINX_RATE_LIMIT_GENERAL_RATE` | nginx rate | `200r/m` | Rate for `general` zone |
| `NGINX_RATE_LIMIT_GENERAL_BURST` | integer | `50` | Burst for catch-all `/` |
| `NGINX_CONN_LIMIT_PER_IP` | integer | `20` | `limit_conn conn_per_ip` value in all location blocks |
| `GO_GATEWAY_IMAGE` | Docker image | `nginx:alpine` | Only used by `go-gateway` service under `stub` profile |

### NGINX_LB_ALGORITHM special handling

This variable is injected as a raw line inside the `upstream go_gateway { }` block.
The value **must be a complete nginx directive including the semicolon**, or empty.

```
NGINX_LB_ALGORITHM=            # round-robin (default, no directive needed)
NGINX_LB_ALGORITHM=least_conn; # least connections
NGINX_LB_ALGORITHM=ip_hash;    # IP hash (session affinity)
```

If you set it to `least_conn` without the semicolon, nginx config validation will fail.

---

## nginx.conf — key decisions

- `worker_processes auto` — nginx auto-detects CPU count; do not hardcode.
- `worker_rlimit_nofile 65535` — must match or be less than the container's `ulimit -n`.
- `worker_connections 4096` — max simultaneous connections per worker. Total capacity = workers × 4096.
- `client_max_body_size 10m` — hardcoded here, not env-templated. Change in `nginx.conf` if uploads require larger bodies.
- Include order: static conf.d/ files first (`logging`, `gzip`, `security`, `ssl-params`, `proxy-params`), then templated files (`rate-limit`, `upstream`, `http-server`, `https-server`). The order within the http block matters only for inheritance; nginx validates all references after full parsing.

---

## conf.d/logging.conf — nuances

- Uses `log_format json_combined escape=json` — the `escape=json` flag properly escapes special characters (quotes, backslashes, control chars) in variable values. Without it, user-supplied input in `$http_user_agent` or `$args` can break JSON structure.
- `buffer=32k flush=5s` on `access_log` — log lines are buffered in memory and flushed every 5 seconds. This reduces I/O at high RPS but means up to 5 seconds of logs can be lost on hard crash. Acceptable for an edge gateway.
- `$upstream_response_time` will contain `-` for requests served directly by nginx (e.g. `/healthz`, `/nginx-status`). This is normal and must be handled in any log processing pipeline.
- `$request_id` is a 32-char hex string generated by nginx (built-in since nginx 1.11.0). It is unique per request and not related to any client header.

---

## conf.d/security.conf — nuances

- `$block_ua` map: evaluated for every request in the HTTPS server block via `if ($block_ua)`. The map uses case-insensitive regex (`~*`). Empty user-agent (`""`) returns `1` (blocked). The Go HTTP client exception (`~*go-http-client/1\.1$`) prevents blocking internal Go services that call back through the edge.
- `$invalid_method` map: blocks `TRACE` and `TRACK` (used in XST attacks). `DELETE` and `PATCH` are explicitly allowed (`0`). All others default to `0` (allowed). Add more methods here if needed.
- `proxy_max_temp_file_size 1024m` is placed here for grouping but is an `http`-context directive that controls how much response body nginx can spool to disk when upstream sends faster than the client reads. This protects upstream from being held open by slow clients.
- The `geo $blocked_ip` block is commented out. To activate IP-based blocking: uncomment the geo block, populate the CIDR ranges, then add `if ($blocked_ip) { return 403; }` inside the HTTPS server block in `https-server.conf.template`.

---

## conf.d/ssl-params.conf — nuances

- `ssl_prefer_server_ciphers off` — for TLS 1.3 this is meaningless (client always chooses); for TLS 1.2 this lets the client pick from the allowed list rather than forcing server order. Mozilla Intermediate profile recommends `off`.
- `ssl_session_tickets off` — session tickets compromise forward secrecy if the ticket key leaks. Disabled in favor of session cache.
- `ssl_session_cache shared:SSL:50m` — 50 MB shared across all workers. 1 MB ≈ 4000 sessions. 50 MB handles ~200k concurrent sessions.
- OCSP stapling requires `ssl_trusted_certificate` (the CA chain) to be set in the server block — this is why `NGINX_SSL_CHAIN_PATH` is a required variable and referenced in `https-server.conf.template`.
- `resolver 1.1.1.1 8.8.8.8` — used for OCSP stapling DNS resolution. In Kubernetes or air-gapped environments, replace with the cluster DNS resolver.
- DH params are commented out. If re-enabled, generate with `openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048` (takes ~30s). Mount the file into the container.

---

## conf.d/proxy-params.conf — nuances

- `proxy_http_version 1.1` + `proxy_set_header Connection ""` — **both are required** for upstream keepalive to function. Without these, nginx uses HTTP/1.0, which does not support persistent connections, making the `keepalive 32` directive in the upstream block useless.
- `proxy_set_header Connection ""` clears the `Connection` header from the client (which might say `close` or list hop-by-hop headers). Clearing it allows keepalive to be negotiated between nginx and the upstream.
- `proxy_hide_header X-Powered-By` and `proxy_hide_header Server` — prevents the Go Gateway from leaking its technology stack in responses.
- `proxy_next_upstream error timeout` — retries the next upstream server ONLY on connection-level failures. Intentionally does NOT include `http_500`, `http_502`, etc. Retrying on 500 would cause side effects (duplicate writes) on non-idempotent requests. If Go Gateway returns a 5xx, that error is passed to the client.
- `proxy_next_upstream_tries 2` — tries at most 2 servers total (1 original + 1 retry). With a single upstream server, this has no effect but is ready for multi-instance deployments.

### proxy_set_header inheritance warning

`proxy_set_header` directives set at `http` context (in proxy-params.conf) are
inherited by all `server` and `location` blocks **only if** that block does not
define ANY `proxy_set_header` of its own. If you add a `proxy_set_header` inside
a `location` block in `https-server.conf.template`, the http-level headers will
be silently dropped for that location. To avoid this, never add `proxy_set_header`
in individual location blocks; make all header changes in `proxy-params.conf`.

---

## nginx/templates/upstream.conf.template — nuances

- The upstream name `go_gateway` is hardcoded. All `proxy_pass http://go_gateway;` directives reference this name. Do not rename it without updating all four template and conf.d files.
- `max_fails=3 fail_timeout=30s` — nginx marks a server as unavailable after 3 consecutive connection failures within 30s. It re-tests the server after 30s. This is passive health checking (nginx does not actively probe).
- Active health checks (`health_check` directive) require `nginx-plus`. The open-source version relies on this passive mechanism. Combine with a monitoring alert on `upstream_status` in access logs to detect degradation.
- `keepalive 32` sets the pool size of idle keepalive connections. It does not limit total connections to the upstream. Tune this to match the Go Gateway's `max_idle_conns` setting.

---

## nginx/templates/https-server.conf.template — nuances

### Location matching order and priority

Three prefix location blocks exist:
```
location ^~ /api/auth/   # highest priority among prefixes (^~ modifier)
location /api/           # longer prefix, wins over /
location /               # catch-all
```

The `^~` modifier on `/api/auth/` ensures regex location blocks (like the
`.git/.env` regex) do not intercept auth routes. For prefix matching without `^~`,
nginx checks regex locations after finding the longest prefix match. With `^~`,
if this prefix matches, nginx stops and uses it — no regex check.

Any new specific prefix routes (e.g., `/api/admin/`) should be added with `^~`
if they must not be intercepted by regex blocks. Add them BEFORE `/api/` in the
template to keep the intent clear, even though nginx would find the longer match
regardless of order.

### Security headers and add_header inheritance

`add_header` at the `server` level is inherited by `location` blocks ONLY if
that location block has zero `add_header` directives. The named error locations
(`@rate_limited`, `@upstream_error`, `@bad_request`) do contain `add_header`
(e.g. `Retry-After` in `@rate_limited`), which means they do NOT inherit the
HSTS and other security headers from the server block. This is intentional for
error responses — adding HSTS to a 429 JSON body is not needed. If you add
`add_header` to a regular location block, verify security headers are still sent.

### HTTP/2

`http2 on;` is the nginx >= 1.25.1 syntax. The old `listen 443 ssl http2;` syntax
is deprecated in nginx 1.27. Do not mix the two. The base image is `nginx:1.27-alpine`.

### /healthz

Returns a static JSON `{"status":"ok","service":"uye-edge"}` from nginx directly —
it does NOT proxy to the Go Gateway. This ensures the health check reflects nginx
availability, not upstream availability. Available on both HTTP (port 80) and
HTTPS (port 443).

### /nginx-status

Exposes `stub_status` data. Access is restricted to RFC-1918 ranges and localhost.
The `nginx-exporter` container scrapes this endpoint at `http://nginx/nginx-status`
over the internal `edge` Docker network.

---

## Docker Compose profiles

| Profile | Services activated | When to use |
|---|---|---|
| _(none)_ | `nginx` only | CI, image build checks |
| `stub` | `nginx` + `go-gateway` (stub) | Integration testing without the real Go Gateway |
| `certbot` | `nginx` + `certbot` | Initial cert issuance; cert renewal via `certbot-renew.sh` |
| `observability` | `nginx` + `nginx-exporter` | When Prometheus scraping is needed |

**Important:** `docker-compose.yml` has `depends_on: go-gateway` for nginx, but
`go-gateway` is under the `stub` profile. This means starting nginx without the
`stub` profile will log a warning about the missing service but will not fail.
In production, the real Go Gateway runs in a separate stack and joins the `edge`
network externally, or the `go-gateway` service is overridden in a
deployment-specific compose file.

---

## Development workflow

```bash
# 1. Generate self-signed cert (one-time)
bash scripts/generate-self-signed.sh
# Creates: certs/dev/selfsigned.crt and certs/dev/selfsigned.key

# 2. Start dev stack (nginx + stub go-gateway + nginx-exporter)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build

# 3. Test
curl -k https://localhost/healthz
curl -k https://localhost/api/anything
curl -k https://localhost/nginx-status  # only from localhost — allowed

# 4. Hot-reload nginx config without restart (dev only — configs are bind-mounted)
docker exec uye-edge nginx -s reload

# 5. Validate config before reloading
docker exec uye-edge nginx -t
```

Dev compose overrides (`docker-compose.dev.yml`):
- Bind-mounts `nginx/`, `nginx/conf.d/`, `nginx/templates/` so config edits take effect on `nginx -s reload` without rebuilding the image.
- Uses `.env.dev` instead of `.env` (10× relaxed rate limits, `localhost` domain).
- Activates `go-gateway` and `nginx-exporter` without requiring profile flags.
- Mounts `./certs/dev` as `/etc/nginx/ssl` (read-only) for the self-signed cert.

---

## Production workflow

### First certificate issuance

```bash
# 1. Set up .env with real domain and email
cp .env.example .env && nano .env

# 2. Start nginx (HTTP only works before cert exists — temporarily comment out
#    the https-server include in nginx.conf to avoid startup failure)
docker compose up -d nginx

# 3. Issue certificate
docker compose --profile certbot run --rm certbot

# 4. Re-enable https-server include, rebuild/restart
docker compose up -d --build nginx
```

### Certificate renewal

```bash
# Run manually or via cron (see scripts/certbot-renew.sh)
0 3 * * * /opt/uye-edge/scripts/certbot-renew.sh >> /var/log/certbot-renew.log 2>&1
```

`certbot-renew.sh` overrides the certbot container command to `renew` (not `certonly`).
After renewal it runs `nginx -s reload` to pick up the new certificate without downtime.

### Cert volume layout (inside container)

```
/etc/nginx/ssl/                              ← certbot_certs volume (mounted :ro in nginx)
└── live/
    └── <NGINX_DOMAIN>/
        ├── fullchain.pem                    ← ssl_certificate
        ├── privkey.pem                      ← ssl_certificate_key
        └── chain.pem                        ← ssl_trusted_certificate (OCSP)
```

`certbot_certs` maps to `/etc/letsencrypt` inside the certbot container, where
Let's Encrypt stores `live/`, `archive/`, `renewal/` directories. Nginx sees it
read-only at `/etc/nginx/ssl`.

---

## Prometheus / observability

```
nginx-exporter  →  GET http://nginx/nginx-status  →  parses stub_status
                ←  exposes :9113/metrics          ←  Prometheus scrapes this
```

Key metrics from nginx-prometheus-exporter:
- `nginx_connections_active` — currently active connections
- `nginx_connections_reading` / `_writing` / `_waiting`
- `nginx_http_requests_total` — total requests handled

For richer metrics (per-route latencies, 4xx/5xx rates, upstream response times),
ship JSON access logs to a log aggregation stack (Loki + Grafana, or ELK).
The `upstream_response_time` and `status` fields in the JSON log are the primary
SLI data sources for Go Gateway latency and error rate.

`X-Request-ID` is the distributed trace carrier. It is:
1. Generated by nginx (`$request_id`, 32-char hex, unique per request).
2. Forwarded to Go Gateway in `X-Request-ID` proxy header (set in proxy-params.conf).
3. Returned to the client in the `X-Request-ID` response header (set in https-server.conf.template).
4. Logged in every access log line as `"request_id":"..."`.

---

## Adding a new route or upstream

1. If the route has different rate limit requirements, add a new `limit_req_zone`
   in `nginx/templates/rate-limit.conf.template` with a new env var, and add the
   var to `.env.example` and `.env.dev`.

2. Add the `location` block to `nginx/templates/https-server.conf.template`.
   - Use `^~` prefix modifier if the route must not be intercepted by regex blocks.
   - Include `limit_req`, `limit_conn`, and `proxy_pass` — do NOT add `proxy_set_header`
     (see inheritance warning above).
   - Place more specific prefixes above less specific ones for clarity, even though
     nginx uses longest-match (not declaration order) for prefix locations.

3. If routing to a different upstream (not `go_gateway`), add a new `upstream`
   block to `upstream.conf.template` and reference it in the location's `proxy_pass`.

4. Rebuild the image or `nginx -s reload` in dev.

---

## Adding configuration to conf.d/ vs templates/

**Use `conf.d/` (static) when:** the directive has no runtime-variable parts —
it is the same in dev, staging, and production (e.g. TLS cipher list, gzip MIME types,
log format, proxy buffer sizes).

**Use `templates/` (envsubst) when:** the directive contains values that differ
between environments or deployments (e.g. domain name, upstream host/port,
rate limit values, cert paths).

Do not introduce env vars into static conf.d/ files. They will not be substituted
and nginx will reject the config with a syntax error.

---

## Known limitations and deliberate omissions

- **Brotli compression** is not available in `nginx:1.27-alpine`. The standard
  nginx binary does not include the `ngx_brotli` module. To add it, switch the
  base image to `fholzer/nginx-brotli` and add a `brotli.conf` in `conf.d/`.

- **Active health checks** (probing upstream on a schedule) require nginx Plus.
  The open-source build uses passive health checks only (`max_fails` / `fail_timeout`
  in the upstream server directive).

- **DH parameters** for DHE cipher suites are commented out. DHE is included in
  the cipher list but effectively unused without `ssl_dhparam`. To enable it:
  generate `dhparam.pem`, mount it into the container, and uncomment the directive
  in `ssl-params.conf`.

- **Caching** is not configured. For API responses, caching is intentionally omitted
  because the Go Gateway owns cache invalidation logic. If edge caching for static
  assets is needed in future, add a `proxy_cache_path` directive and a `location`
  block with `proxy_cache`.

- **WAF / ModSecurity** is not included. The scanner-UA blocking and method filtering
  in `security.conf` are lightweight guards, not a full WAF. For ModSecurity, use
  the `owasp/modsecurity-crs:nginx-alpine` base image.

- **Multiple domains / SAN** are not explicitly configured. The `server_name` directive
  uses `${NGINX_DOMAIN} www.${NGINX_DOMAIN}`. For additional domains, either add
  them to the template as additional env vars or run separate nginx instances.
