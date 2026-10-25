# Proxy Nginx

Production-ready nginx reverse proxy with SSL/TLS support, SSE streaming optimization, and maintenance pages.

Part of the [PocketDev](https://github.com/tetrixdev/pocket-dev) ecosystem.

## Features

- **SSL/TLS Termination** - Let's Encrypt via Certbot with auto-renewal
- **SSE Streaming Optimization** - `ssl_buffer_size 1400` for smooth Server-Sent Events
- **WebSocket Support** - Dynamic connection upgrade headers
- **HTTP/2** - On for every domain, so streaming apps don't exhaust the browser's per-origin connections
- **Tokens masked in logs** - `token=` / `access_token=` query values are logged as `[REDACTED]`
- **Maintenance Pages** - Automatic fallback on 502/503 errors
- **Security** - Blocks direct IP access, hides nginx version
- **One-Line Install** - Get up and running in seconds

## Quick Start

### One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
```

With a specific version:

```bash
VERSION=1.4.0 curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
```

Running the installer on a host that already has proxy-nginx is an **upgrade in place**:
`conf.d/default.conf` (which holds every domain block) is never overwritten, a pre-1.4
single-file `default.conf` is migrated into `conf.d/`, and the stateless fragments
(`conf.d/10-http2.conf`) are laid down on every run. It prompts only on a terminal;
use `FORCE=1` for automation.

### Manual Setup

```bash
# Get version to deploy
VERSION="1.4.0"

# Clone and copy files
git clone --depth 1 --branch "v$VERSION" https://github.com/tetrixdev/proxy-nginx.git /tmp/proxy-nginx
mkdir -p ~/docker-apps/proxy-nginx/conf.d && cd ~/docker-apps/proxy-nginx
cp /tmp/proxy-nginx/compose/compose.yml .
# FRESH INSTALL ONLY. conf.d/default.conf holds every domain domain.sh has added, so
# copying the template over an existing one wipes them all. On an existing host use
# install.sh, which upgrades in place and preserves the live config.
[ -f conf.d/default.conf ] || cp /tmp/proxy-nginx/compose/conf.d/default.conf conf.d/
# Stateless fragments (HTTP/2, and anything added later). Always safe to copy: they
# hold no domains, so unlike default.conf the release's copy is always the right one.
cp /tmp/proxy-nginx/compose/conf.d/[0-9]*.conf conf.d/
rm -rf /tmp/proxy-nginx

# Update version in compose.yml
sed -i "s/REPLACE_WITH_VERSION/$VERSION/g" compose.yml

# Start
docker compose up -d
```

## Domain Management

Use the built-in domain script to manage nginx configurations:

### Add a Proxy Domain

```bash
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=app.example.com \
  --upstream=myapp-nginx
```

### Add a Redirect Domain

```bash
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=example.com \
  --redirect=https://www.example.com
```

### Advanced Options

```bash
# Domain with IP whitelist (Tailscale + specific IP)
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=staging.example.com \
  --upstream=staging-nginx \
  --whitelist="100.64.0.0/10,203.0.113.50"

# Domain with basic auth
docker exec proxy-nginx /scripts/htpasswd.sh add --user=admin --password=secret
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=admin.example.com \
  --upstream=admin-nginx \
  --basic-auth='admin:$apr1$...'

# Custom body size and timeout
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=upload.example.com \
  --upstream=upload-nginx \
  --max-body-size=1G \
  --websocket-timeout=3600s

# Upstream that streams large uploads itself (request bodies not saved to the proxy's disk)
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=files.example.com \
  --upstream=files-app \
  --max-body-size=6G \
  --stream-uploads
```

Every option is regenerated on each upsert, so repeat the ones you want to keep.
An upsert of a domain that already has a certificate keeps certbot's `listen 443 ssl`
and `ssl_*` lines, so changing an option never takes a domain off HTTPS.

### Remove a Domain

```bash
docker exec proxy-nginx /scripts/domain.sh delete --domain=old.example.com
```

### List Managed Domains

```bash
docker exec proxy-nginx /scripts/domain.sh list
```

### Script Reference

| Option | Description | Default |
|--------|-------------|---------|
| `--domain` | Domain name (required) | - |
| `--upstream` | Upstream container name | - |
| `--redirect` | Redirect target URL | - |
| `--whitelist` | Comma-separated IP/CIDR allowlist | - |
| `--basic-auth` | Basic auth `user:hash` | - |
| `--max-body-size` | Max upload size | `256M` |
| `--websocket-timeout` | WebSocket/SSE timeout | `600s` |
| `--stream-uploads` | Stream request bodies to the upstream instead of buffering them on the proxy's disk (`proxy_request_buffering off`); not for PHP-FPM upstreams | off |
| `--comment` | Label for config block | - |
| `--no-reload` | Skip nginx reload | - |

### Manual Configuration

For complex configurations, edit `conf.d/default.conf` directly (prefer `domain.sh`: it validates with `nginx -t` before reloading). Use `# BEGIN domain` and `# END domain` markers if you want the script to manage the block later:

```nginx
# BEGIN www.example.com
# My custom config
server {
    server_name www.example.com;
    # ... custom configuration ...
    listen 80;
}
# END www.example.com
```

Reload nginx after manual changes:

```bash
docker exec proxy-nginx nginx -s reload
```

## SSL Certificates

Request certificates with Certbot:

```bash
# Single domain
docker exec -it proxy-nginx certbot --nginx -d www.example.com

# Multiple domains
docker exec -it proxy-nginx certbot --nginx -d www.example.com -d example.com
```

Certificates auto-renew via cron (runs twice daily).

### SSL with IP Whitelist

Domains with `--whitelist` can still use Let's Encrypt HTTP-01 challenge. The domain script automatically adds an exception for `/.well-known/acme-challenge/` that allows Let's Encrypt's validation servers to reach your domain, even when other traffic is blocked.

```bash
# This works! SSL certificates with IP whitelist
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=private.example.com \
  --upstream=myapp-nginx \
  --whitelist="100.64.0.0/10"

docker exec -it proxy-nginx certbot --nginx -d private.example.com
```

Whitelisted domains always also allow Docker's internal ranges (`172.16.0.0/12`,
`192.168.0.0/16`), so container-to-container traffic (health checks, a headless
browser on the same host) never trips the whitelist. An external client can never
present those source addresses at this edge proxy. Existing whitelisted domains pick
this up on their next upsert.

## Redirect Domains

For www redirects or domain aliases:

```nginx
server {
    server_name example.com;
    return 308 https://www.example.com$request_uri;
    listen 80;
}
```

## Configuration Reference

### HTTP/2

On by default, for every domain, via `conf.d/10-http2.conf` (`http2 on;` at http level,
nginx 1.25.1+).

It matters most for anything that **streams**. A browser allows only six connections
per origin over HTTP/1.1, and a Server-Sent Events connection holds one of them open
for as long as the page wants it, so an app with a few live streams spends its whole
budget and every later request waits in the browser's own queue until a stream ends.
HTTP/2 carries many streams over one connection, so the cap stops applying.

The setting is deliberately **not** on a `listen` line: `domain.sh` regenerates a server
block from its own template plus whatever `listen 443` / `ssl_*` lines certbot left, so
`listen 443 ssl http2` would be erased the next time that domain was touched.

### Access log: tokens masked

The image ships its own `/etc/nginx/nginx.conf` (the nginx:1.27-alpine stock file with
one change): `token=` and `access_token=` query values in the logged request line are
replaced by `[REDACTED]`, so a client that puts a credential in a URL (for example a
WebSocket upgrade) does not leave it in the logs. The error log can still print the raw
request line on upstream errors.

### SSE Streaming

The `ssl_buffer_size 1400` setting is critical for Server-Sent Events. The default 16KB buffer causes "wait, burst" behavior where data accumulates before being sent. Setting it to ~1 TCP packet size (1400 bytes) ensures smooth streaming.

For SSE endpoints, also send this header from your application:

```php
header('X-Accel-Buffering: no');
```

### Timeouts

Default timeouts are 10 minutes (600s) for long-running connections like SSE streams. Adjust in the location block if needed:

```nginx
proxy_read_timeout 600s;
proxy_send_timeout 600s;
```

### Maintenance Page

When the upstream container is unavailable (502) or in maintenance mode (503), nginx automatically serves `/var/www/html/maintenance.html`.

To customize, mount your own maintenance page:

```yaml
volumes:
  - ./maintenance.html:/var/www/html/maintenance.html
```

## Docker Compose Reference

```yaml
services:
  proxy-nginx:
    image: ghcr.io/tetrixdev/proxy-nginx:1.4.0
    container_name: proxy-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./conf.d:/etc/nginx/conf.d   # a directory, not a single file
    networks:
      - main-network
    restart: always

networks:
  main-network:
    name: main-network
```

## Networking

This proxy expects backend containers to be on the `main-network` Docker network. Ensure your application compose files include:

```yaml
networks:
  main-network:
    external: true
```

## Logs

```bash
# View proxy logs
docker compose logs -f proxy-nginx

# View nginx access log
docker exec proxy-nginx tail -f /var/log/nginx/access.log

# View nginx error log
docker exec proxy-nginx tail -f /var/log/nginx/error.log
```

## Troubleshooting

### Container won't start

Check for config errors:

```bash
docker exec proxy-nginx nginx -t
```

### SSL certificate issues

Check certbot logs:

```bash
docker exec proxy-nginx cat /var/log/letsencrypt/letsencrypt.log
```

### Backend unreachable

Ensure the backend container is on `main-network`:

```bash
docker network inspect main-network
```

## License

MIT - See [LICENSE](LICENSE) for details.
