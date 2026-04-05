#!/bin/bash
# =============================================================================
# TransIP DNS-01 Setup Script
# =============================================================================
# Sets up TransIP credentials for automatic wildcard SSL certificates.
#
# USAGE:
#   transip-setup.sh setup --login=USERNAME --key-file=/path/to/key.pem
#   transip-setup.sh wildcard --domain=example.com
#   transip-setup.sh status
#
# =============================================================================

set -euo pipefail

CREDENTIALS_FILE="/etc/letsencrypt/transip/credentials.ini"
CREDENTIALS_DIR="/etc/letsencrypt/transip"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat <<EOF
TransIP DNS-01 Setup for Wildcard SSL Certificates

COMMANDS:
  setup     Configure TransIP API credentials
  wildcard  Request a wildcard SSL certificate
  status    Check if TransIP is configured

SETUP OPTIONS:
  --login=USERNAME      TransIP login username
  --key-file=PATH       Path to TransIP API private key file
  --key=KEY             TransIP API private key (inline, use quotes)

WILDCARD OPTIONS:
  --domain=DOMAIN       Base domain for wildcard cert (e.g., dev.example.com)
  --email=EMAIL         Email for Let's Encrypt notifications (optional)

EXAMPLES:
  # Setup with key file
  transip-setup.sh setup --login=myuser --key-file=/tmp/transip.key

  # Request wildcard certificate
  transip-setup.sh wildcard --domain=dev.example.com

  # Check status
  transip-setup.sh status
EOF
}

cmd_setup() {
    local login=""
    local key=""
    local key_file=""

    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --login=*) login="${arg#*=}" ;;
            --key=*) key="${arg#*=}" ;;
            --key-file=*) key_file="${arg#*=}" ;;
            *) log_error "Unknown option: $arg"; exit 1 ;;
        esac
    done

    if [ -z "$login" ]; then
        log_error "Missing --login parameter"
        exit 1
    fi

    if [ -z "$key" ] && [ -z "$key_file" ]; then
        log_error "Missing --key or --key-file parameter"
        exit 1
    fi

    # Read key from file if provided
    if [ -n "$key_file" ]; then
        if [ ! -f "$key_file" ]; then
            log_error "Key file not found: $key_file"
            exit 1
        fi
        key=$(cat "$key_file")
    fi

    # Validate key format
    if [[ ! "$key" =~ "BEGIN PRIVATE KEY" ]]; then
        log_error "Invalid private key format. Must start with '-----BEGIN PRIVATE KEY-----'"
        exit 1
    fi

    # Create credentials directory
    mkdir -p "$CREDENTIALS_DIR"

    # Write credentials file in INI format for certbot-dns-transip
    cat > "$CREDENTIALS_FILE" <<EOF
dns_transip_username = $login
dns_transip_key_file = ${CREDENTIALS_DIR}/private.key
EOF

    # Write private key to separate file
    echo "$key" > "${CREDENTIALS_DIR}/private.key"

    # Secure the credentials
    chmod 600 "$CREDENTIALS_FILE"
    chmod 600 "${CREDENTIALS_DIR}/private.key"

    log_info "TransIP credentials configured successfully"
    log_info "Credentials file: $CREDENTIALS_FILE"
}

cmd_wildcard() {
    local domain=""
    local email=""

    # Parse arguments
    for arg in "$@"; do
        case $arg in
            --domain=*) domain="${arg#*=}" ;;
            --email=*) email="${arg#*=}" ;;
            *) log_error "Unknown option: $arg"; exit 1 ;;
        esac
    done

    if [ -z "$domain" ]; then
        log_error "Missing --domain parameter"
        exit 1
    fi

    # Check if credentials are configured
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        log_error "TransIP credentials not configured. Run 'transip-setup.sh setup' first."
        exit 1
    fi

    log_info "Requesting wildcard certificate for $domain and *.$domain"

    # Build certbot command
    local certbot_args=(
        certonly
        --authenticator dns-transip
        --dns-transip-credentials "$CREDENTIALS_FILE"
        --dns-transip-propagation-seconds 120
        -d "$domain"
        -d "*.$domain"
        --non-interactive
        --agree-tos
    )

    if [ -n "$email" ]; then
        certbot_args+=(--email "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
    fi

    # Request certificate
    if certbot "${certbot_args[@]}"; then
        log_info "Wildcard certificate obtained successfully!"
        log_info "Certificate location: /etc/letsencrypt/live/$domain/"
        log_info ""
        log_info "The certificate covers:"
        log_info "  - $domain"
        log_info "  - *.$domain (all subdomains)"
        log_info ""
        log_info "Renewal is automatic via the existing certbot cron job."
    else
        log_error "Failed to obtain certificate"
        exit 1
    fi
}

cmd_status() {
    echo "TransIP DNS-01 Configuration Status"
    echo "===================================="
    echo ""

    if [ -f "$CREDENTIALS_FILE" ]; then
        local username=$(grep "dns_transip_username" "$CREDENTIALS_FILE" | cut -d'=' -f2 | tr -d ' ')
        echo -e "Credentials: ${GREEN}Configured${NC}"
        echo "  Username: $username"
        echo "  Key file: ${CREDENTIALS_DIR}/private.key"
    else
        echo -e "Credentials: ${RED}Not configured${NC}"
        echo ""
        echo "Run 'transip-setup.sh setup --login=USER --key-file=KEY' to configure"
        return
    fi

    echo ""
    echo "Certificates using DNS-01:"

    # Find certificates that use DNS-01 (wildcard certs)
    if [ -d "/etc/letsencrypt/live" ]; then
        for cert_dir in /etc/letsencrypt/live/*/; do
            if [ -d "$cert_dir" ]; then
                local domain=$(basename "$cert_dir")
                if [ "$domain" != "README" ]; then
                    local expiry=$(openssl x509 -enddate -noout -in "${cert_dir}fullchain.pem" 2>/dev/null | cut -d= -f2)
                    echo "  - $domain (expires: $expiry)"
                fi
            fi
        done
    else
        echo "  (none)"
    fi
}

# Main
case "${1:-}" in
    setup)
        shift
        cmd_setup "$@"
        ;;
    wildcard)
        shift
        cmd_wildcard "$@"
        ;;
    status)
        cmd_status
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
