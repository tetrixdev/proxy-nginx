# CLAUDE.md - AI Context for proxy-nginx

## Project Overview

This is `tetrixdev/proxy-nginx`, a Docker-based nginx reverse proxy for production Laravel deployments. It handles SSL termination, WebSocket/SSE streaming, and maintenance pages.

## Key Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Alpine-based nginx with certbot, cron |
| `docker-entrypoint-custom` | Starts cron for cert renewal |
| `compose/compose.yml` | Docker Compose template |
| `compose/default.conf` | Nginx config template |
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
| `--whitelist` | - | IP/CIDR allowlist (comma-separated) |
| `--basic-auth` | - | htpasswd format `user:hash` |
| `--max-body-size` | `256M` | Upload size limit |
| `--websocket-timeout` | `600s` | SSE/WebSocket timeout |
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

This allows upsert (update if exists, create if not) and clean deletion.

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

## Networking

All backend containers must be on `main-network` Docker network. The proxy uses Docker's internal DNS (`127.0.0.11`) to resolve container names.

## Versioning

- Config template version tracked in `default.conf` header
- Docker images tagged with semver (e.g., `1.0.0`)
- Breaking changes = major version bump
