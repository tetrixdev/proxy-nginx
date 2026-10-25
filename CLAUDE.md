# CLAUDE.md - AI Context for proxy-nginx

## Project Overview

This is `tetrixdev/proxy-nginx`, a Docker-based nginx reverse proxy for production Laravel deployments. It handles SSL termination, WebSocket/SSE streaming, and maintenance pages.

## Key Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Alpine-based nginx with certbot, cron |
| `nginx.conf` | Base nginx config shipped in the image: the stock nginx:1.27-alpine file, with `token=`/`access_token=` masked in the access log |
| `docker-entrypoint-custom` | Starts cron for cert renewal |
| `compose/compose.yml` | Docker Compose template |
| `compose/conf.d/default.conf` | Nginx config template (managed by `domain.sh`); seeded into `conf.d/default.conf` on a fresh install only, never overwritten |
| `compose/conf.d/10-http2.conf` | `http2 on;` for every domain. Every `compose/conf.d/*.conf` except `default.conf` is stateless and laid down by `install.sh` on every run, so a file added here reaches every host on its next upgrade |
| `html/maintenance.html` | Fallback page for 502/503 |
| `install.sh` | One-line installer script |
| `scripts/domain.sh` | Domain upsert/delete management |
| `scripts/htpasswd.sh` | Basic auth user management |

## Critical Configuration

### SSE Streaming Optimization

The most important setting for AI/LLM applications:

```nginx
ssl_buffer_size 1400;
```

This prevents the "wait, burst" streaming pattern by reducing TLS record buffering from 16KB to ~1 TCP packet.

### WebSocket/SSE Headers

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

### Timeouts

10-minute timeouts for long-running connections:

```nginx
proxy_read_timeout 600s;
proxy_send_timeout 600s;
```

### HTTP/2

`conf.d/10-http2.conf` sets `http2 on;` at http level (nginx 1.25.1+). Not on a `listen`
line: that is the line certbot rewrites and `domain.sh` regenerates.

## Config layout (1.4.0+)

`compose.yml` mounts `./conf.d` as a **directory** at `/etc/nginx/conf.d`. Before 1.4.0 it
mounted `./default.conf` as a single file, which binds the inode: any host-side
replace-and-rename (`sed -i`, `mv`, most editors) orphaned the mount, and inside the
container `sed -i` failed outright ("Resource busy"), so `domain.sh` could not update or
delete an existing domain. `install.sh` migrates a pre-1.4 host into `conf.d/`, taking the
config from the running container when it differs from the host file, and backs up both.

Still prefer `domain.sh` over hand-editing the config: it validates with `nginx -t` and
manages the `# BEGIN`/`# END` blocks.

## certbot rewrites our config, and `domain.sh` has to cope

`certbot --nginx` does not add a server block of its own. It **rewrites ours**: it swaps
`listen 80;` for `listen 443 ssl;` inside the `# BEGIN`/`# END` block and appends the
certificate paths. Two consequences `domain.sh` handles, and any change to it must keep
handling:

- **An upsert regenerates the block from scratch, so it carries certbot's SSL lines
  across** (`extract_ssl_directives()`). Without that, a routine upsert (a max-body-size,
  a whitelist) silently drops the domain off HTTPS.
- **certbot reflows the file and can glue a marker to the preceding brace** (`}# END
  app.example.com`). Lookups anchor markers to the start of a line, so `list` would hide
  the domain, `delete` miss it, and `upsert` append a duplicate. `normalize_markers()`
  repairs this before every command.

## Domain Management Scripts

### Add/Update a Domain (upsert)

```bash
# Proxy domain
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=app.example.com \
  --upstream=myapp-nginx

# Redirect domain
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=example.com \
  --redirect=https://www.example.com

# With IP whitelist (Tailscale subnet + specific IP)
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=staging.example.com \
  --upstream=staging-nginx \
  --whitelist="100.64.0.0/10,203.0.113.50"

# With basic auth
docker exec proxy-nginx /scripts/domain.sh upsert \
  --domain=admin.example.com \
  --upstream=admin-nginx \
  --basic-auth='admin:$apr1$xyz...'
```

### Delete a Domain

```bash
docker exec proxy-nginx /scripts/domain.sh delete --domain=old.example.com
```

### List Managed Domains

```bash
docker exec proxy-nginx /scripts/domain.sh list
```

### Script Options

| Option | Default | Description |
|--------|---------|-------------|
| `--domain` | required | Domain name |
| `--upstream` | - | Container to proxy to |
| `--redirect` | - | Redirect target URL |
| `--whitelist` | - | IP/CIDR allowlist (comma-separated); ACME challenges bypass it. Internal Docker networks (`172.16.0.0/12`, `192.168.0.0/16`) are always allowed so container-to-container traffic and headless testing never trip it |
| `--basic-auth` | - | htpasswd format `user:hash` |
| `--max-body-size` | `256M` | Upload size limit |
| `--websocket-timeout` | `600s` | SSE/WebSocket timeout |
| `--stream-uploads` | off | Stream request bodies to the upstream instead of saving them to the proxy's disk first (`proxy_request_buffering off`). For upstreams that handle streams; leave off for PHP-FPM, where buffering keeps a slow upload from holding a worker. Refused with `--redirect` |
| `--comment` | - | Label in config |
| `--no-reload` | - | Skip nginx reload |

### Basic Auth Helper

```bash
# Add user (creates htpasswd file if needed)
docker exec proxy-nginx /scripts/htpasswd.sh add --user=admin --password=secret

# Generate hash only (for --basic-auth flag)
docker exec proxy-nginx /scripts/htpasswd.sh hash --password=secret

# Remove user
docker exec proxy-nginx /scripts/htpasswd.sh remove --user=admin

# List users
docker exec proxy-nginx /scripts/htpasswd.sh list
```

### Block Markers

The script uses markers to manage config blocks:

```nginx
# BEGIN app.example.com
# Managed by proxy-nginx
server {
    server_name app.example.com;
    ...
}
# END app.example.com
```

This allows upsert (update if exists, create if not) and clean deletion. Every option is
regenerated on each upsert, so repeat the ones to keep; certbot's SSL lines are kept.

## Common Tasks

### Test config syntax
```bash
docker exec proxy-nginx nginx -t
```

### Reload after config changes
```bash
docker exec proxy-nginx nginx -s reload
```

### Request SSL certificate
```bash
docker exec -it proxy-nginx certbot --nginx -d domain.com
```

### Renew all certificates
```bash
docker exec proxy-nginx certbot renew
```

### View active config
```bash
docker exec proxy-nginx cat /etc/nginx/conf.d/default.conf
```

On the host it is `~/docker-apps/proxy-nginx/conf.d/default.conf`.

## Networking

All backend containers must be on `main-network` Docker network. The proxy uses Docker's internal DNS (`127.0.0.11`) to resolve container names.

## Versioning

- Config template version tracked in `compose/conf.d/default.conf` header
- Docker images tagged with semver (e.g., `1.0.0`)
- Breaking changes = major version bump
