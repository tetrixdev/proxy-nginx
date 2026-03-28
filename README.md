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

## Adding Domains

Edit `default.conf` to add your domains:

```nginx
server {
    server_name www.example.com;

    client_max_body_size 256M;
    root /var/www/html;

    # SSE Streaming Optimization
    ssl_buffer_size 1400;

    location / {
        set $upstream http://example-app-nginx;
        resolver 127.0.0.11 valid=30s;

        proxy_pass $upstream;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Host $host;
        proxy_redirect off;

        # WebSocket/SSE support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # Long-running connection timeouts (10 min)
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        # Maintenance page fallback
        proxy_intercept_errors on;
        error_page 502 503 /maintenance.html;
    }

    location = /maintenance.html {
        internal;
        root /var/www/html;
    }

    listen 80;
}
```

Reload nginx after changes:

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
