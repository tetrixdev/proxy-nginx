#!/bin/bash
# =============================================================================
# PocketDev Proxy Nginx Installer
# =============================================================================
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
#
# With specific version:
#   VERSION=1.4.0 curl -fsSL https://raw.githubusercontent.com/tetrixdev/proxy-nginx/main/install.sh | bash
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

# Check if already installed. This is an UPGRADE, not an overwrite: the live config and
# its domains are preserved (see the config-layout section below).
#
# The prompt must not be reachable non-interactively. Under `curl … | bash` the script is
# itself on stdin, so `read` would eat a byte of the script and see an empty reply; under
# `bash install.sh </dev/null` it returns EOF and `set -e` kills the run before any work.
# Either way the documented one-line upgrade silently did nothing. So: prompt only when
# stdin is a terminal, and offer FORCE=1 for automation (provisioning scripts drive this headless).
if [ -d "$INSTALL_DIR" ]; then
    log_warn "Directory $INSTALL_DIR already exists — upgrading in place."
    log_warn "The live config and its domain blocks are preserved."
    if [ "${FORCE:-0}" != "1" ] && [ -t 0 ]; then
        read -rp "Continue? (y/N): " -n 1 REPLY
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
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

# Download release tarball (try v-prefixed tag first, then bare)
curl -fsSL "$REPO_URL/archive/refs/tags/v$VERSION.tar.gz" -o "$TEMP_DIR/release.tar.gz" 2>/dev/null || \
curl -fsSL "$REPO_URL/archive/refs/tags/$VERSION.tar.gz" -o "$TEMP_DIR/release.tar.gz"

# Extract
tar -xzf "$TEMP_DIR/release.tar.gz" -C "$TEMP_DIR"

# Find extracted directory
EXTRACTED_DIR=$(ls -d "$TEMP_DIR"/*/ | head -1)

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy compose file (always safe to replace — it carries no state)
cp "$EXTRACTED_DIR/compose/compose.yml" "$INSTALL_DIR/"

# -----------------------------------------------------------------------------
# Config layout
# -----------------------------------------------------------------------------
# 1.4+ mounts conf.d/ as a DIRECTORY; earlier releases mount default.conf as a single
# FILE. This script always comes from main, but compose.yml comes from the *pinned*
# release tarball — so the layout we deploy is dictated by the release, never by this
# script. Deploying the 1.4 layout alongside a 1.3 compose.yml leaves the file mount
# pointing at a path that no longer exists: Docker then creates a DIRECTORY there and
# nginx never starts, taking every app on the host down with it.
if grep -qE '\./conf\.d:/etc/nginx/conf\.d' "$EXTRACTED_DIR/compose/compose.yml"; then
    RELEASE_USES_CONF_DIR=true
    CONF_LIVE="$INSTALL_DIR/conf.d/default.conf"
else
    RELEASE_USES_CONF_DIR=false
    CONF_LIVE="$INSTALL_DIR/default.conf"
fi
CONF_LEGACY="$INSTALL_DIR/default.conf"
CONF_NEW="$INSTALL_DIR/conf.d/default.conf"

# Refuse to downgrade a directory-mount install onto a file-mount release: the config
# would stop being mounted at all and the proxy would fail to start.
if [ "$RELEASE_USES_CONF_DIR" = false ] && [ -f "$CONF_NEW" ]; then
    log_error "This host uses the conf.d/ layout, but v$VERSION mounts default.conf as a single file."
    log_error "Installing it would leave the config unmounted and the proxy unable to start."
    log_error "Install 1.4.0 or newer, or migrate conf.d/default.conf back by hand first."
    exit 1
fi

# Both layouts present: ambiguous, and guessing wrong silently drops every domain. This
# is reachable from an interrupted run or the pre-1.4 manual-install path.
if [ -f "$CONF_LEGACY" ] && [ -f "$CONF_NEW" ]; then
    log_error "Both $CONF_LEGACY and $CONF_NEW exist — cannot tell which one is live."
    log_error "Keep the one holding your domain blocks (grep '# BEGIN'), delete the other, re-run."
    exit 1
fi

mkdir -p "$(dirname "$CONF_LIVE")"

# The running container is the ONLY authority on what is actually being served. A file
# bind mount binds the inode, so if anything on the host ever replaced that file (sed -i,
# mv, an editor), the container is still attached to the old, orphaned inode and is
# serving a config the host file has never seen — including every domain domain.sh added
# since. Recreating the container is exactly what destroys that. So read the live config
# out of the container first, and prefer it whenever it differs.
#
# Gated on the container, not on the host file: a host whose default.conf was deleted but
# whose container still serves the orphan would otherwise get the template seeded over it
# and lose everything on recreate.
LIVE_CONF="$TEMP_DIR/live-default.conf"
HAVE_LIVE=false

# "docker failed" and "container is not running" must not look the same. Swallowing a
# daemon or permission error as "no container" would send us down the fall-back path and
# install the stale host config over live domains — the exact loss this guards against.
DOCKER_PS_ERR="$TEMP_DIR/docker-ps.err"
if ! DOCKER_PS_OUT=$(docker ps --format '{{.Names}}' 2>"$DOCKER_PS_ERR"); then
    log_error "Cannot talk to Docker — refusing to guess whether proxy-nginx is running."
    log_error "$(cat "$DOCKER_PS_ERR")"
    log_error "A live container may be serving domains the host config does not have."
    exit 1
fi

if printf '%s\n' "$DOCKER_PS_OUT" | grep -qx 'proxy-nginx'; then
    # The container IS running, so its config is the authority. Failing to read it is fatal:
    # proceeding would fall back to the host file and could drop whatever it is serving.
    if ! docker exec proxy-nginx cat /etc/nginx/conf.d/default.conf > "$LIVE_CONF" 2>"$DOCKER_PS_ERR"; then
        log_error "proxy-nginx is running but its config could not be read:"
        log_error "$(cat "$DOCKER_PS_ERR")"
        log_error "Refusing to continue — it may be serving domains the host config does not have."
        exit 1
    fi
    if [ ! -s "$LIVE_CONF" ]; then
        log_error "proxy-nginx returned an EMPTY config. Refusing to continue on a truncated read."
        exit 1
    fi
    HAVE_LIVE=true
fi

# Install a config atomically: write beside the target, then rename into place. A partial
# write would otherwise be indistinguishable from a good config on the next run (its mere
# existence is the "already installed" signal) and would stop nginx from starting.
install_conf() {
    local src="$1" dst="$2" dir tmp
    dir="$(dirname "$dst")"
    # mktemp rather than a name we compose ourselves. It creates the file O_EXCL, so
    # it cannot be talked into following a symlink planted at a name someone guessed,
    # and it is unique, so two installs running at once cannot land on the same path
    # (the old `.default.conf.$$` was neither, and was shared by every caller).
    tmp="$(mktemp "$dir/.conf.XXXXXXXX")" || return 1
    # The temp file stays in the DESTINATION directory: same filesystem, so the mv
    # below is a rename and the install stays atomic. mktemp creates 0600, and this
    # config is meant to be world-readable (it is bind-mounted into the container),
    # so set the mode explicitly instead of inheriting either side's.
    if ! cp "$src" "$tmp" || ! chmod 644 "$tmp" || ! mv "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
}

CONF_TS=$(date +%Y%m%d-%H%M%S)

if [ "$HAVE_LIVE" = true ]; then
    if [ -f "$CONF_LIVE" ] && cmp -s "$LIVE_CONF" "$CONF_LIVE"; then
        : # Host and container agree — nothing to do.
    elif [ -f "$CONF_LEGACY" ] || [ -f "$CONF_NEW" ]; then
        # Diverged, or a pre-1.4 layout being migrated. Keep what nginx is serving, and
        # back up both sides so nothing is thrown away either way.
        EXISTING_CONF="$CONF_LEGACY"; [ -f "$CONF_NEW" ] && EXISTING_CONF="$CONF_NEW"
        cp "$EXISTING_CONF" "$INSTALL_DIR/default.conf.host-$CONF_TS.bak"
        cp "$LIVE_CONF" "$INSTALL_DIR/default.conf.container-$CONF_TS.bak"

        # Domains present on the host but NOT in the container would be dropped by taking
        # the container's copy. That should never happen (domain.sh only writes inside the
        # container), so treat it as unexplained and stop rather than lose a domain.
        # LC_ALL=C: comm requires both inputs sorted in the SAME collation, and a non-C
        # locale can order them differently than comm expects — silently corrupting the one
        # check that decides whether a domain would be dropped.
        HOST_ONLY=$(LC_ALL=C comm -23 \
            <(grep -o '# BEGIN [^ ]*' "$EXISTING_CONF" | LC_ALL=C sort -u) \
            <(grep -o '# BEGIN [^ ]*' "$LIVE_CONF" | LC_ALL=C sort -u) || true)
        if [ -n "$HOST_ONLY" ]; then
            log_error "The host config has domain blocks the running container does not:"
            log_error "$HOST_ONLY"
            log_error "Taking the container's config would drop them. Reconcile by hand, then re-run."
            log_error "Both copies saved as $INSTALL_DIR/default.conf.{host,container}-$CONF_TS.bak"
            exit 1
        fi

        if ! cmp -s "$LIVE_CONF" "$EXISTING_CONF"; then
            log_warn "Host config and running container had DIVERGED (orphaned file bind mount)."
            log_warn "Kept the container's live config — it is the one nginx is serving."
            log_warn "Both versions saved as $INSTALL_DIR/default.conf.{host,container}-$CONF_TS.bak"
        fi
        install_conf "$LIVE_CONF" "$CONF_LIVE"
    else
        # No config on the host at all, but the container is serving one — rescue it.
        log_warn "No config on the host, but proxy-nginx is serving one — recovered it from the container."
        install_conf "$LIVE_CONF" "$CONF_LIVE"
    fi
elif [ -f "$CONF_LEGACY" ] && [ "$RELEASE_USES_CONF_DIR" = true ]; then
    # Pre-1.4 layout, proxy not running: the host file is all we have, and it is what the
    # container would have mounted on start anyway.
    cp "$CONF_LEGACY" "$INSTALL_DIR/default.conf.host-$CONF_TS.bak"
    install_conf "$CONF_LEGACY" "$CONF_NEW"
    log_warn "proxy-nginx is not running — migrated the host config as-is."
    log_warn "If domains are missing afterwards, restore from $INSTALL_DIR/default.conf.host-$CONF_TS.bak"
elif [ ! -f "$CONF_LIVE" ]; then
    # Genuinely fresh install: seed the template. Never do this when a config exists — it
    # holds every domain domain.sh has added.
    # 1.4.0+ ships the template inside compose/conf.d/, mirroring where it is mounted.
    # Older release tarballs still carry it one level up, and this script always runs
    # from main against a PINNED release, so both paths have to keep working.
    CONF_SRC="$EXTRACTED_DIR/compose/conf.d/default.conf"
    [ -f "$CONF_SRC" ] || CONF_SRC="$EXTRACTED_DIR/compose/default.conf"
    install_conf "$CONF_SRC" "$CONF_LIVE"
    log_info "Seeded the default config template (fresh install)"
fi

# Stateless config fragments, laid down every run.
#
# Unlike default.conf -- which holds every domain block domain.sh has written and is
# therefore never replaced above -- these carry no state, so the release's copy is
# always the right one. Same reasoning as compose.yml at the top of this script.
#
# Only on the directory layout: a file-mount release has nowhere to put them, and
# writing them beside an unmounted path would be a silent no-op that looks like it
# worked.
if [ "$RELEASE_USES_CONF_DIR" = true ]; then
    for fragment in "$EXTRACTED_DIR"/compose/conf.d/*.conf; do
        [ -f "$fragment" ] || continue
        case "$(basename "$fragment")" in default.conf) continue ;; esac
        install_conf "$fragment" "$INSTALL_DIR/conf.d/$(basename "$fragment")"
    done
fi

# The legacy file is only removed once the new one is safely in place.
if [ "$RELEASE_USES_CONF_DIR" = true ] && [ -f "$CONF_LEGACY" ] && [ -s "$CONF_NEW" ]; then
    rm -f "$CONF_LEGACY"
    log_info "Migrated config into conf.d/ (file mount -> directory mount)"
fi

if [ ! -s "$CONF_LIVE" ]; then
    log_error "No usable config at $CONF_LIVE — refusing to start the proxy with an empty config."
    exit 1
fi

# Create letsencrypt directory now, as this user: the validation run below mounts it,
# and a bind mount of a missing path makes Docker create it owned by root.
mkdir -p "$INSTALL_DIR/letsencrypt"

# Validate before the container is recreated. Starting a broken config takes every app on
# this host offline, and the recreate is irreversible (it destroys any orphaned inode).
if ! docker run --rm -v "$(dirname "$CONF_LIVE"):/etc/nginx/conf.d:ro" \
        -v "$INSTALL_DIR/letsencrypt:/etc/letsencrypt:ro" \
        --entrypoint nginx "ghcr.io/tetrixdev/proxy-nginx:$VERSION" -t 2>/dev/null; then
    log_warn "nginx -t did not pass against the config that is about to be mounted."
    log_warn "Config kept at $CONF_LIVE; backups (if any) are $INSTALL_DIR/default.conf.*.bak"
    log_error "Refusing to recreate the proxy with a config nginx rejects."
    exit 1
fi
log_info "Config validated (nginx -t)"

# Update version in compose.yml
sed -i "s/REPLACE_WITH_VERSION/$VERSION/g" "$INSTALL_DIR/compose.yml"

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

if docker compose ps | grep -qE '\(healthy\)|\brunning\b'; then
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
echo "  1. Add a domain:"
echo "     docker exec proxy-nginx /scripts/domain.sh upsert \\"
echo "       --domain=your-domain.com --upstream=your-app-nginx"
echo ""
echo "  2. Request SSL certificate:"
echo "     docker exec -it proxy-nginx certbot --nginx -d your-domain.com"
echo ""
echo "  3. List managed domains:"
echo "     docker exec proxy-nginx /scripts/domain.sh list"
echo ""
echo "  4. View logs:"
echo "     docker compose -f $INSTALL_DIR/compose.yml logs -f"
echo ""
echo "  More options: docker exec proxy-nginx /scripts/domain.sh --help"
echo ""
echo "============================================================================="
