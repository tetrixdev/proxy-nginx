#!/bin/bash
# =============================================================================
# PocketDev Proxy Nginx Installer
# =============================================================================
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
#
# With specific version:
#   VERSION=1.0.0 curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}==>${NC} $1"; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

INSTALL_DIR="${INSTALL_DIR:-$HOME/docker-apps/proxy-nginx}"
REPO="tetrixdev/proxy-nginx"
REPO_URL="https://github.com/$REPO"

# -----------------------------------------------------------------------------
# Get version
# -----------------------------------------------------------------------------

if [ -z "${VERSION:-}" ]; then
    log_step "Fetching latest version..."
    VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//')
    if [ -z "$VERSION" ]; then
        log_error "Could not determine latest version. Please specify VERSION env var."
        exit 1
    fi
fi

log_info "Installing proxy-nginx version: $VERSION"

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

log_step "Running pre-flight checks..."

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose is not available. Please install Docker Compose."
    exit 1
fi

# Check if already installed
if [ -d "$INSTALL_DIR" ]; then
    log_warn "Directory $INSTALL_DIR already exists."
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

log_info "Pre-flight checks passed"

# -----------------------------------------------------------------------------
# Download and install
# -----------------------------------------------------------------------------

log_step "Downloading proxy-nginx v$VERSION..."

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Download release tarball
curl -fsSL "$REPO_URL/archive/refs/tags/v$VERSION.tar.gz" -o "$TEMP_DIR/release.tar.gz" 2>/dev/null || \
curl -fsSL "$REPO_URL/archive/refs/tags/$VERSION.tar.gz" -o "$TEMP_DIR/release.tar.gz"

# Extract
tar -xzf "$TEMP_DIR/release.tar.gz" -C "$TEMP_DIR"

# Find extracted directory
EXTRACTED_DIR=$(ls -d "$TEMP_DIR"/*/ | head -1)

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy compose files
cp "$EXTRACTED_DIR/compose/compose.yml" "$INSTALL_DIR/"
cp "$EXTRACTED_DIR/compose/default.conf" "$INSTALL_DIR/"

# Update version in compose.yml
sed -i "s/REPLACE_WITH_VERSION/$VERSION/g" "$INSTALL_DIR/compose.yml"

# Create letsencrypt directory
mkdir -p "$INSTALL_DIR/letsencrypt"

log_info "Files installed to $INSTALL_DIR"

# -----------------------------------------------------------------------------
# Start container
# -----------------------------------------------------------------------------

log_step "Starting proxy-nginx..."

cd "$INSTALL_DIR"
docker compose pull
docker compose up -d

# Wait for container to be healthy
log_info "Waiting for container to be ready..."
sleep 5

if docker compose ps | grep -q "healthy\|running"; then
    log_info "Container is running"
else
    log_warn "Container may not be fully ready yet. Check with: docker compose ps"
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

echo ""
echo "============================================================================="
echo -e "${GREEN}Proxy Nginx installed successfully!${NC}"
echo "============================================================================="
echo ""
echo "Installation directory: $INSTALL_DIR"
echo "Version: $VERSION"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit the config to add your domains:"
echo "     nano $INSTALL_DIR/default.conf"
echo ""
echo "  2. Reload nginx after changes:"
echo "     docker exec proxy-nginx nginx -s reload"
echo ""
echo "  3. Request SSL certificates:"
echo "     docker exec -it proxy-nginx certbot --nginx -d your-domain.com"
echo ""
echo "  4. View logs:"
echo "     docker compose -f $INSTALL_DIR/compose.yml logs -f"
echo ""
echo "============================================================================="
