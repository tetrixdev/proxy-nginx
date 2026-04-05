#!/bin/sh
# proxy-nginx htpasswd helper
# Usage: /scripts/htpasswd.sh <command> [options]
#
# Commands:
#   add       Add or update a user
#   remove    Remove a user
#   list      List all users
#   hash      Generate a password hash (for use with domain.sh --basic-auth)
#
# Examples:
#   /scripts/htpasswd.sh add --user=admin --password=secret
#   /scripts/htpasswd.sh remove --user=admin
#   /scripts/htpasswd.sh list
#   /scripts/htpasswd.sh hash --password=secret

set -e

HTPASSWD_FILE="/etc/nginx/.htpasswd"

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

usage() {
    cat << 'EOF'
Usage: htpasswd.sh <command> [options]

Commands:
  add       Add or update a user in the htpasswd file
  remove    Remove a user from the htpasswd file
  list      List all users in the htpasswd file
  hash      Generate a password hash (output only, doesn't modify files)

Options:
  --user=USERNAME     Username (required for add, remove)
  --password=PASS     Password (required for add, hash)

Examples:
  # Add a user (creates file if needed)
  htpasswd.sh add --user=admin --password=mysecret

  # Generate hash for use with domain.sh
  htpasswd.sh hash --password=mysecret
  # Output: $apr1$... (use this with domain.sh --basic-auth=admin:$apr1$...)

  # Remove a user
  htpasswd.sh remove --user=admin

  # List all users
  htpasswd.sh list
EOF
    exit 1
}

# Generate APR1 hash using OpenSSL
# This is compatible with Apache htpasswd format
generate_apr1_hash() {
    password="$1"

    # Generate random salt (8 characters)
    salt=$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 8)

    # Use openssl to generate the hash
    # apr1 is the Apache variant of MD5 (not great, but widely compatible)
    hash=$(openssl passwd -apr1 -salt "$salt" "$password")

    echo "$hash"
}

cmd_add() {
    if [ -z "$USER" ] || [ -z "$PASSWORD" ]; then
        log_error "--user and --password are required"
        exit 1
    fi

    # Create file if it doesn't exist
    touch "$HTPASSWD_FILE"

    # Generate hash
    hash=$(generate_apr1_hash "$PASSWORD")

    # Remove existing entry for this user
    if grep -q "^${USER}:" "$HTPASSWD_FILE" 2>/dev/null; then
        sed -i "/^${USER}:/d" "$HTPASSWD_FILE"
        log_info "Updating existing user: $USER"
    else
        log_info "Adding new user: $USER"
    fi

    # Add the entry
    echo "${USER}:${hash}" >> "$HTPASSWD_FILE"
    log_info "User $USER added/updated successfully"
}

cmd_remove() {
    if [ -z "$USER" ]; then
        log_error "--user is required"
        exit 1
    fi

    if [ ! -f "$HTPASSWD_FILE" ]; then
        log_error "htpasswd file does not exist"
        exit 1
    fi

    if ! grep -q "^${USER}:" "$HTPASSWD_FILE"; then
        log_error "User $USER not found"
        exit 1
    fi

    sed -i "/^${USER}:/d" "$HTPASSWD_FILE"
    log_info "User $USER removed"
}

cmd_list() {
    if [ ! -f "$HTPASSWD_FILE" ]; then
        echo "(no htpasswd file)"
        return 0
    fi

    if [ ! -s "$HTPASSWD_FILE" ]; then
        echo "(no users)"
        return 0
    fi

    log_info "Users in $HTPASSWD_FILE:"
    cut -d: -f1 "$HTPASSWD_FILE" | while read -r user; do
        echo "  - $user"
    done
}

cmd_hash() {
    if [ -z "$PASSWORD" ]; then
        log_error "--password is required"
        exit 1
    fi

    hash=$(generate_apr1_hash "$PASSWORD")
    echo "$hash"
}

# Parse arguments
COMMAND=""
USER=""
PASSWORD=""

if [ $# -lt 1 ]; then
    usage
fi

COMMAND="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --user=*)
            USER="${1#*=}"
            ;;
        --password=*)
            PASSWORD="${1#*=}"
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

case "$COMMAND" in
    add)
        cmd_add
        ;;
    remove)
        cmd_remove
        ;;
    list)
        cmd_list
        ;;
    hash)
        cmd_hash
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        ;;
esac
