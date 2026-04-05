# Proxy Nginx

Production-ready nginx reverse proxy with SSL/TLS support, SSE streaming optimization, and maintenance pages.

Part of the [PocketDev](https://github.com/tetrixdev/pocket-dev) ecosystem.

## Features

- **SSL/TLS Termination** - Let's Encrypt via Certbot with auto-renewal
- **SSE Streaming Optimization** - `ssl_buffer_size 1400` for smooth Server-Sent Events
- **WebSocket Support** - Dynamic connection upgrade headers
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
VERSION=1.0.0 curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
```

### Manual Setup

```bash
# Get version to deploy
VERSION="1.0.0"

# Clone and copy files
git clone --depth 1 --branch "$VERSION" https://github.com/tetrixdev/proxy-nginx.git /tmp/proxy-nginx
mkdir -p ~/docker-apps/proxy-nginx && cd ~/docker-apps/proxy-nginx
cp /tmp/proxy-nginx/compose/compose.yml /tmp/proxy-nginx/compose/default.conf .
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
```

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
| `--comment` | Label for config block | - |
| `--no-reload` | Skip nginx reload | - |

### Manual Configuration

For complex configurations, edit `default.conf` directly. Use `# BEGIN domain` and `# END domain` markers if you want the script to manage the block later:

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

### Single Domain (HTTP-01 Challenge)

For public domains, use the standard HTTP-01 challenge:

```bash
# Single domain
docker exec -it proxy-nginx certbot --nginx -d www.example.com

# Multiple domains
docker exec -it proxy-nginx certbot --nginx -d www.example.com -d example.com
```

### Wildcard Certificates with TransIP (DNS-01 Challenge)

For wildcard certificates (`*.example.com`) or domains behind Tailscale/firewalls, use the DNS-01 challenge with TransIP:

```bash
# 1. Configure TransIP credentials (one-time setup)
docker exec proxy-nginx /scripts/transip-setup.sh setup \
  --login=your-transip-username \
  --key-file=/path/to/transip-private-key.pem

# 2. Request wildcard certificate
docker exec proxy-nginx /scripts/transip-setup.sh wildcard --domain=example.com

# 3. Check status
docker exec proxy-nginx /scripts/transip-setup.sh status
```

This will obtain a certificate covering both `example.com` and `*.example.com`.

**Requirements:**
- Domain must be registered/managed at TransIP
- TransIP API access must be enabled in your account
- Generate an API private key at https://www.transip.nl/cp/account/api/

**Credentials format:**
- Login: Your TransIP username
- Private key: PEM format (starts with `-----BEGIN PRIVATE KEY-----`)

Certificates auto-renew via cron (runs twice daily).

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
    image: ghcr.io/tetrixdev/proxy-nginx:1.0.0
    container_name: proxy-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./default.conf:/etc/nginx/conf.d/default.conf
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
