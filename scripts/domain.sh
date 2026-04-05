#!/bin/sh
# proxy-nginx domain management script
# Usage: /scripts/domain.sh <command> [options]
#
# Commands:
#   upsert    Create or update a domain configuration
#   delete    Remove a domain configuration
#   list      List all managed domains
#
# Examples:
#   /scripts/domain.sh upsert --domain=example.com --upstream=app-nginx
#   /scripts/domain.sh upsert --domain=example.com --redirect=https://www.example.com
#   /scripts/domain.sh delete --domain=example.com
#   /scripts/domain.sh list

set -e

# Configuration
CONFIG_FILE="${NGINX_CONFIG_FILE:-/etc/nginx/conf.d/default.conf}"
HTPASSWD_FILE="/etc/nginx/.htpasswd"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# Show usage
usage() {
    cat << 'EOF'
Usage: domain.sh <command> [options]

Commands:
  upsert    Create or update a domain configuration
  delete    Remove a domain configuration
  list      List all managed domains

Upsert Options:
  --domain=DOMAIN           Domain name (required)
  --upstream=CONTAINER      Upstream container name (for proxy type)
  --redirect=URL            Redirect target URL (for redirect type)
  --comment=TEXT            Comment/label for the config block
  --whitelist=CIDRS         Comma-separated IP/CIDR allowlist
  --basic-auth=USER:HASH    Basic auth credentials (htpasswd format)
  --max-body-size=SIZE      Max upload size (default: 256M)
  --websocket-timeout=TIME  WebSocket/SSE timeout (default: 600s)
  --ssl-only                Force HTTPS redirect (flag)
  --no-reload               Don't reload nginx after changes

Delete Options:
  --domain=DOMAIN           Domain name (required)
  --no-reload               Don't reload nginx after changes

Examples:
  # Standard proxy domain
  domain.sh upsert --domain=app.example.com --upstream=myapp-nginx

  # Redirect domain (www redirect)
  domain.sh upsert --domain=example.com --redirect=https://www.example.com

  # Domain with IP whitelist (Tailscale + office)
  domain.sh upsert --domain=staging.example.com --upstream=staging-nginx \
    --whitelist="100.64.0.0/10,203.0.113.50"

  # Domain with basic auth
  domain.sh upsert --domain=admin.example.com --upstream=admin-nginx \
    --basic-auth='admin:$apr1$xyz...'

  # Delete a domain
  domain.sh delete --domain=old.example.com
EOF
    exit 1
}

# Validate domain format
validate_domain() {
    domain="$1"
    # Allow: example.com, sub.example.com, *.example.com
    if ! echo "$domain" | grep -qE '^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'; then
        log_error "Invalid domain format: $domain"
        exit 1
    fi
}

# Check if domain block exists
domain_exists() {
    domain="$1"
    grep -q "^# BEGIN $domain\$" "$CONFIG_FILE" 2>/dev/null
}

# Remove domain block from config
remove_domain_block() {
    domain="$1"
    if domain_exists "$domain"; then
        # Use sed to remove lines between BEGIN and END markers (inclusive)
        sed -i "/^# BEGIN $domain\$/,/^# END $domain\$/d" "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Generate proxy server block
generate_proxy_block() {
    cat << NGINX
# BEGIN $DOMAIN
# $COMMENT
# Generated: $(date -Iseconds)
server {
    server_name $DOMAIN;
    client_max_body_size $MAX_BODY_SIZE;
    root /var/www/html;
    ssl_buffer_size 1400;
NGINX

    # IP whitelist
    if [ -n "$WHITELIST" ]; then
        echo ""
        echo "    # IP Whitelist"
        echo "$WHITELIST" | tr ',' '\n' | while read -r cidr; do
            cidr=$(echo "$cidr" | tr -d ' ')
            [ -n "$cidr" ] && echo "    allow $cidr;"
        done
        echo "    deny all;"
    fi

    # Basic auth
    if [ -n "$BASIC_AUTH" ]; then
        echo ""
        echo "    # Basic Authentication"
        echo "    auth_basic \"Restricted Access\";"
        echo "    auth_basic_user_file $HTPASSWD_FILE;"
    fi

    cat << NGINX

    location / {
        set \$upstream http://$UPSTREAM;
        resolver 127.0.0.11 valid=30s;

        proxy_pass \$upstream;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Host \$host;
        proxy_redirect off;

        # WebSocket/SSE support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Timeouts
        proxy_read_timeout $WEBSOCKET_TIMEOUT;
        proxy_send_timeout $WEBSOCKET_TIMEOUT;

        # Maintenance page fallback
        proxy_intercept_errors on;
        error_page 502 503 /maintenance.html;
    }

    location = /maintenance.html {
        internal;
        root /var/www/html;
    }

    location /maintenance-assets/ {
        alias /var/www/html/maintenance-assets/;
    }

    listen 80;
}
# END $DOMAIN
NGINX
}

# Generate redirect server block
generate_redirect_block() {
    cat << NGINX
# BEGIN $DOMAIN
# $COMMENT
# Generated: $(date -Iseconds)
server {
    server_name $DOMAIN;
    return 308 $REDIRECT\$request_uri;
    listen 80;
}
# END $DOMAIN
NGINX
}

# Generate SSL-only redirect block (used when --ssl-only is set)
generate_ssl_redirect_block() {
    cat << NGINX
# BEGIN ${DOMAIN}_http_redirect
# HTTP to HTTPS redirect for $DOMAIN
# Generated: $(date -Iseconds)
server {
    server_name $DOMAIN;
    listen 80;
    return 301 https://\$host\$request_uri;
}
# END ${DOMAIN}_http_redirect
NGINX
}

# Reload nginx
reload_nginx() {
    if [ "$NO_RELOAD" = "true" ]; then
        log_info "Skipping nginx reload (--no-reload)"
        return 0
    fi

    log_info "Testing nginx configuration..."
    if nginx -t 2>&1; then
        log_info "Reloading nginx..."
        nginx -s reload
        log_info "Nginx reloaded successfully"
    else
        log_error "Nginx configuration test failed!"
        exit 1
    fi
}

# Add basic auth user to htpasswd file
setup_basic_auth() {
    if [ -z "$BASIC_AUTH" ]; then
        return 0
    fi

    # Extract username from user:hash format
    auth_user=$(echo "$BASIC_AUTH" | cut -d: -f1)
    auth_hash=$(echo "$BASIC_AUTH" | cut -d: -f2-)

    if [ -z "$auth_user" ] || [ -z "$auth_hash" ]; then
        log_error "Invalid basic auth format. Use: user:\$apr1\$..."
        exit 1
    fi

    # Create htpasswd file if it doesn't exist
    touch "$HTPASSWD_FILE"

    # Remove existing entry for this user (if any)
    if grep -q "^${auth_user}:" "$HTPASSWD_FILE" 2>/dev/null; then
        sed -i "/^${auth_user}:/d" "$HTPASSWD_FILE"
    fi

    # Add the entry
    echo "${auth_user}:${auth_hash}" >> "$HTPASSWD_FILE"
    log_info "Basic auth configured for user: $auth_user"
}

# Command: upsert
cmd_upsert() {
    if [ -z "$DOMAIN" ]; then
        log_error "--domain is required"
        exit 1
    fi

    validate_domain "$DOMAIN"

    if [ -z "$UPSTREAM" ] && [ -z "$REDIRECT" ]; then
        log_error "Either --upstream or --redirect is required"
        exit 1
    fi

    if [ -n "$UPSTREAM" ] && [ -n "$REDIRECT" ]; then
        log_error "Cannot specify both --upstream and --redirect"
        exit 1
    fi

    # Set defaults
    COMMENT="${COMMENT:-Managed by proxy-nginx}"
    MAX_BODY_SIZE="${MAX_BODY_SIZE:-256M}"
    WEBSOCKET_TIMEOUT="${WEBSOCKET_TIMEOUT:-600s}"

    # Setup basic auth if specified
    setup_basic_auth

    # Remove existing block if present
    if domain_exists "$DOMAIN"; then
        log_info "Updating existing configuration for $DOMAIN"
        remove_domain_block "$DOMAIN"
    else
        log_info "Creating new configuration for $DOMAIN"
    fi

    # Generate and append the new block
    if [ -n "$REDIRECT" ]; then
        generate_redirect_block >> "$CONFIG_FILE"
        log_info "Created redirect: $DOMAIN -> $REDIRECT"
    else
        generate_proxy_block >> "$CONFIG_FILE"
        log_info "Created proxy: $DOMAIN -> $UPSTREAM"

        if [ -n "$WHITELIST" ]; then
            log_info "IP whitelist: $WHITELIST"
        fi

        if [ -n "$BASIC_AUTH" ]; then
            log_info "Basic auth: enabled"
        fi
    fi

    reload_nginx
    log_info "Domain $DOMAIN configured successfully"
}

# Command: delete
cmd_delete() {
    if [ -z "$DOMAIN" ]; then
        log_error "--domain is required"
        exit 1
    fi

    validate_domain "$DOMAIN"

    if ! domain_exists "$DOMAIN"; then
        log_warn "Domain $DOMAIN not found in configuration"
        exit 0
    fi

    log_info "Removing configuration for $DOMAIN"
    remove_domain_block "$DOMAIN"

    # Also remove HTTP redirect block if it exists
    if domain_exists "${DOMAIN}_http_redirect"; then
        remove_domain_block "${DOMAIN}_http_redirect"
    fi

    reload_nginx
    log_info "Domain $DOMAIN removed successfully"
}

# Command: list
cmd_list() {
    log_info "Managed domains in $CONFIG_FILE:"
    echo ""

    if ! grep -q "^# BEGIN " "$CONFIG_FILE" 2>/dev/null; then
        echo "  (none)"
        return 0
    fi

    grep "^# BEGIN " "$CONFIG_FILE" | sed 's/^# BEGIN /  - /' | grep -v "_http_redirect$"
}

# Parse command line arguments
COMMAND=""
DOMAIN=""
UPSTREAM=""
REDIRECT=""
COMMENT=""
WHITELIST=""
BASIC_AUTH=""
MAX_BODY_SIZE=""
WEBSOCKET_TIMEOUT=""
SSL_ONLY="false"
NO_RELOAD="false"

# First argument is the command
if [ $# -lt 1 ]; then
    usage
fi

COMMAND="$1"
shift

# Parse remaining arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --domain=*)
            DOMAIN="${1#*=}"
            ;;
        --upstream=*)
            UPSTREAM="${1#*=}"
            ;;
        --redirect=*)
            REDIRECT="${1#*=}"
            ;;
        --comment=*)
            COMMENT="${1#*=}"
            ;;
        --whitelist=*)
            WHITELIST="${1#*=}"
            ;;
        --basic-auth=*)
            BASIC_AUTH="${1#*=}"
            ;;
        --max-body-size=*)
            MAX_BODY_SIZE="${1#*=}"
            ;;
        --websocket-timeout=*)
            WEBSOCKET_TIMEOUT="${1#*=}"
            ;;
        --ssl-only)
            SSL_ONLY="true"
            ;;
        --no-reload)
            NO_RELOAD="true"
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# Execute command
case "$COMMAND" in
    upsert)
        cmd_upsert
        ;;
    delete)
        cmd_delete
        ;;
    list)
        cmd_list
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        ;;
esac
