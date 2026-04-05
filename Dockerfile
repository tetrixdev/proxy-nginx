FROM nginx:1.27-alpine

# Install certbot and dependencies
RUN apk add --no-cache \
    certbot \
    certbot-nginx \
    openssl \
    dcron \
    bash \
    py3-pip

# Install certbot-dns-transip plugin for automatic DNS-01 challenges
# This enables wildcard SSL certificates with TransIP DNS
RUN pip3 install --no-cache-dir --break-system-packages certbot-dns-transip

# Create directory for TransIP credentials
RUN mkdir -p /etc/letsencrypt/transip

# Create SSL directory and generate self-signed certificate for default server block
RUN mkdir -p /etc/nginx/ssl && \
    openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout /etc/nginx/ssl/selfsigned.key \
    -out /etc/nginx/ssl/selfsigned.crt \
    -subj "/C=XX/ST=State/L=City/O=PocketDev/OU=Proxy/CN=localhost"

# Copy maintenance page files
COPY html /var/www/html

# Copy domain management scripts
COPY scripts /scripts
RUN chmod +x /scripts/*.sh

# Copy custom entrypoint
COPY docker-entrypoint-custom /usr/local/bin/docker-entrypoint-custom
RUN chmod +x /usr/local/bin/docker-entrypoint-custom

# Set up certbot renewal cron job (runs twice daily)
RUN echo "0 0,12 * * * certbot renew --quiet --deploy-hook 'nginx -s reload'" > /etc/crontabs/root

ENTRYPOINT ["docker-entrypoint-custom"]
CMD ["nginx", "-g", "daemon off;"]
