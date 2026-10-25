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
  --stream-uploads          Pass request bodies to the upstream as they arrive,
                            instead of saving them to the proxy's disk first
                            (for upstreams that stream large uploads; not PHP-FPM)
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

  # Upstream that streams large uploads itself
  domain.sh upsert --domain=files.example.com --upstream=files-app \
    --max-body-size=6G --stream-uploads

  # Delete a domain
  domain.sh delete --domain=old.example.com
EOF
    exit 1
}

# Normalize domain (lowercase)
normalize_domain() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Validate domain format
validate_domain() {
    domain="$1"
    # Allow: example.com, sub.example.com, *.example.com, example.com:8080
    if ! echo "$domain" | grep -qE '^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]+)?$'; then
        log_error "Invalid domain format: $domain"
        exit 1
    fi
}

# Put every marker back at the start of its own line.
#
# certbot's nginx installer does not edit the file in place: it reparses it and
# writes it back out from its own tree, and a comment that followed a `}` can
# come back glued to it:
#
#     }# BEGIN app.example.com
#
# Every lookup below anchors the marker to the start of a line (`^# BEGIN`), so
# one glued marker makes this script BLIND to a domain it manages:
#   - `upsert` does not find the block, so it APPENDS a second one. nginx keeps
#     serving the first ("conflicting server name"), so the upsert reports
#     success and changes nothing.
#   - `delete` cannot find the block and leaves it in place.
#   - `list` stops showing the domain at all.
#
# So repair the file before looking at it. Idempotent, and it heals a config
# that is already damaged. It matches only a hostname-shaped marker at the end
# of a line, so prose that merely mentions "# BEGIN <domain>" is left alone.
normalize_markers() {
    [ -f "$CONFIG_FILE" ] || return 0
    grep -qE '[^[:space:]]# (BEGIN|END) [A-Za-z0-9._*:-]+$' "$CONFIG_FILE" 2>/dev/null || return 0

    _tmp=$(mktemp)
    sed -E 's/([^[:space:]])(# (BEGIN|END) [A-Za-z0-9._*:-]+)$/\1\n\2/' "$CONFIG_FILE" > "$_tmp"
    cat "$_tmp" > "$CONFIG_FILE"
    rm -f "$_tmp"
    log_warn "Repaired one or more # BEGIN/# END markers that were not at the start of a line."
}

# Check if domain block exists
domain_exists() {
    domain="$1"
    grep -q "^# BEGIN $domain\$" "$CONFIG_FILE" 2>/dev/null
}

# The SSL directives certbot injected INTO our block, so we can put them back.
#
# `certbot --nginx` does not add a block of its own for the served domain: it
# rewrites OURS, swapping `listen 80;` for `listen 443 ssl;` and adding the
# certificate paths. Because every upsert regenerates the block from scratch,
# a later upsert (changing a max-body-size, a whitelist) would silently take the
# domain OFF HTTPS: nginx -t passes and the reload succeeds, but certbot's
# separate port-80 block still redirects to https and nothing listens on 443
# for that name any more, so browsers land on the default server.
#
# Carry them across instead. If the domain has no cert yet this is empty and
# the block gets `listen 80;` exactly as before.
extract_ssl_directives() {
    domain="$1"
    [ -f "$CONFIG_FILE" ] || return 0

    sed -n "/^# BEGIN $domain\$/,/^# END $domain\$/p" "$CONFIG_FILE" 2>/dev/null \
        | grep -E '^[[:space:]]*(listen (\[::\]:)?443|ssl_certificate|ssl_certificate_key|include .*options-ssl-nginx|ssl_dhparam)' \
        || true
}

# The listen/SSL tail of a generated block: whatever certbot had put there, or
# plain port 80.
generate_listen_directives() {
    if [ -n "$SSL_DIRECTIVES" ]; then
        printf '%s\n' "$SSL_DIRECTIVES"
    else
        printf '    listen 80;\n'
    fi
}

# Remove domain block from config.
# Write to a temp file and `cat` it back rather than `sed -i`: `cat >` truncates
# the same inode in place, while `sed -i` renames a new file over the old one,
# which fails ("Device or resource busy") on a pre-1.4 install where
# default.conf is a single-file bind mount.
remove_domain_block() {
    domain="$1"
    if domain_exists "$domain"; then
        _tmp=$(mktemp)
        sed "/^# BEGIN $domain\$/,/^# END $domain\$/d" "$CONFIG_FILE" > "$_tmp"
        cat "$_tmp" > "$CONFIG_FILE"
        rm -f "$_tmp"
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
        echo ""
        echo "    # Always trust internal Docker networks. Container-to-container"
        echo "    # traffic (health checks, and a headless browser on the same host"
        echo "    # reaching an app for testing) must never trip the whitelist. These"
        echo "    # are Docker's default bridge address pools: 172.16.0.0/12 covers"
        echo "    # docker0 plus every compose/user-defined network, and"
        echo "    # 192.168.0.0/16 is the fallback pool used once the 172 space fills."
        echo "    # Safe on this edge proxy: an external client can never present an"
        echo "    # RFC1918 source address here."
        echo "    allow 172.16.0.0/12;"
        echo "    allow 192.168.0.0/16;"
        echo "    deny all;"
        echo ""
        echo "    # Allow ACME challenge for SSL certificates (bypasses IP whitelist)"
        echo "    location ^~ /.well-known/acme-challenge/ {"
        echo "        allow all;"
        echo "        root /var/www/html;"
        echo "    }"
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
NGINX

    # Request bodies streamed straight through (--stream-uploads). Off by default
    # on purpose: buffering is what keeps a slow client from holding one of an
    # upstream's few PHP workers for the whole length of its upload. An upstream
    # that handles streams itself (and must not have uploads land on this
    # proxy's disk) asks for it per domain.
    if [ "$STREAM_UPLOADS" = "true" ]; then
        echo ""
        echo "        # Stream request bodies to the upstream as they arrive (--stream-uploads)"
        echo "        proxy_request_buffering off;"
    fi

    cat << NGINX

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

NGINX

    # certbot's SSL directives if this domain already has a cert, else port 80.
    generate_listen_directives

    cat << NGINX
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
NGINX

    generate_listen_directives

    cat << NGINX
}
# END $DOMAIN
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

    # Normalize to lowercase
    DOMAIN=$(normalize_domain "$DOMAIN")

    validate_domain "$DOMAIN"

    if [ -z "$UPSTREAM" ] && [ -z "$REDIRECT" ]; then
        log_error "Either --upstream or --redirect is required"
        exit 1
    fi

    if [ -n "$UPSTREAM" ] && [ -n "$REDIRECT" ]; then
        log_error "Cannot specify both --upstream and --redirect"
        exit 1
    fi

    if [ -n "$REDIRECT" ] && [ "$STREAM_UPLOADS" = "true" ]; then
        log_error "--stream-uploads is not supported with --redirect: a redirect has no upstream"
        exit 1
    fi

    # Set defaults
    COMMENT="${COMMENT:-Managed by proxy-nginx}"
    MAX_BODY_SIZE="${MAX_BODY_SIZE:-256M}"
    WEBSOCKET_TIMEOUT="${WEBSOCKET_TIMEOUT:-600s}"

    # Setup basic auth if specified
    setup_basic_auth

    # A marker certbot glued to the previous `}` would make us miss our own
    # block and append a duplicate instead of updating it. Repair before we look.
    normalize_markers

    # Remove existing block if present
    SSL_DIRECTIVES=""
    if domain_exists "$DOMAIN"; then
        log_info "Updating existing configuration for $DOMAIN"
        # Rescue certbot's SSL lines BEFORE the block goes: it is regenerated
        # from scratch, and without this the domain silently drops off HTTPS.
        SSL_DIRECTIVES=$(extract_ssl_directives "$DOMAIN")
        if [ -n "$SSL_DIRECTIVES" ]; then
            log_info "Preserving existing SSL configuration (certificate stays in place)"
        fi
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

        if [ "$STREAM_UPLOADS" = "true" ]; then
            log_info "Stream uploads: enabled (proxy_request_buffering off)"
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

    # Normalize to lowercase
    DOMAIN=$(normalize_domain "$DOMAIN")

    validate_domain "$DOMAIN"

    # A glued marker would make us report "not found" for a domain that is there.
    normalize_markers

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
    # Without this, a domain whose marker certbot glued to the previous `}` is
    # simply missing from the listing.
    normalize_markers

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
STREAM_UPLOADS=""
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
        --stream-uploads)
            STREAM_UPLOADS="true"
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
