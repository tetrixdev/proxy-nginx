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

## Adding a New Domain

1. Add server block to `default.conf`
2. Reload nginx: `docker exec proxy-nginx nginx -s reload`
3. Request SSL: `docker exec -it proxy-nginx certbot --nginx -d domain.com`

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
