#!/usr/bin/env bash
#
# Download and install Docker Engine static binaries and the Docker Compose
# CLI plugin on a single online Linux machine.
#
# Default versions are pinned below. The script is self-contained and does not
# depend on a manifest or any other repository file.
#
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --docker-data-root /data2/docker
#   sudo ./install.sh --docker-version 29.7.2 \
#       --compose-version v5.5.0
#
# Optional environment variables for mirrors:
#   DOCKER_DOWNLOAD_BASE=https://download.docker.com/linux/static/stable
#   COMPOSE_DOWNLOAD_BASE=https://github.com/docker/compose/releases/download

set -euo pipefail

DOCKER_VERSION="${DOCKER_VERSION:-29.7.2}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v5.5.0}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/data/docker}"
DOCKER_DOWNLOAD_BASE="${DOCKER_DOWNLOAD_BASE:-https://download.docker.com/linux/static/stable}"
COMPOSE_DOWNLOAD_BASE="${COMPOSE_DOWNLOAD_BASE:-https://github.com/docker/compose/releases/download}"
FORCE=false

usage() {
    sed -n '2,17p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker-version)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            DOCKER_VERSION="$2"
            shift 2
            ;;
        --compose-version)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            COMPOSE_VERSION="$2"
            shift 2
            ;;
        --docker-data-root)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            DOCKER_DATA_ROOT="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

log() {
    printf '[docker-install] %s\n' "$*"
}

fail() {
    printf '[docker-install] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run this script as root (for example: sudo $0)."
fi

[[ "$(uname -s)" == "Linux" ]] || fail "Only Linux is supported."
command -v systemctl >/dev/null 2>&1 || fail "systemd/systemctl is required."

for command_name in curl tar install mktemp; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "Required command not found: $command_name"
done

case "$(uname -m)" in
    x86_64|amd64)
        DOCKER_ARCH="x86_64"
        COMPOSE_ARCH="x86_64"
        ;;
    aarch64|arm64)
        DOCKER_ARCH="aarch64"
        COMPOSE_ARCH="aarch64"
        ;;
    *)
        fail "Unsupported CPU architecture: $(uname -m)"
        ;;
esac

[[ -n "$DOCKER_VERSION" ]] || fail "Docker version cannot be empty."
[[ -n "$COMPOSE_VERSION" ]] || fail "Compose version cannot be empty."
[[ "$DOCKER_DATA_ROOT" == /* ]] || fail "Docker data root must be an absolute path."
[[ "$DOCKER_DATA_ROOT" =~ ^/[[:alnum:]_./:@+-]+$ ]] \
    || fail "Docker data root contains unsupported characters."

if [[ "$COMPOSE_VERSION" != v* ]]; then
    COMPOSE_VERSION="v$COMPOSE_VERSION"
fi

DOCKER_URL="${DOCKER_DOWNLOAD_BASE%/}/${DOCKER_ARCH}/docker-${DOCKER_VERSION}.tgz"
COMPOSE_URL="${COMPOSE_DOWNLOAD_BASE%/}/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}"
COMPOSE_PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"
COMPOSE_PLUGIN="$COMPOSE_PLUGIN_DIR/docker-compose"
DOCKER_UNIT="/etc/systemd/system/docker.service"
DOCKER_BIN="/usr/bin/docker"
DOCKERD_BIN="/usr/bin/dockerd"

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

download() {
    local url="$1"
    local destination="$2"

    log "Downloading $url"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
        --output "$destination" "$url"
}

DOCKER_CHANGED=false
if [[ "$FORCE" != "true" ]] \
    && [[ -x "$DOCKER_BIN" ]] \
    && [[ -x "$DOCKERD_BIN" ]] \
    && "$DOCKER_BIN" --version 2>/dev/null | grep -Fq "Docker version $DOCKER_VERSION"; then
    log "Docker $DOCKER_VERSION is already installed; skipping binaries."
else
    DOCKER_ARCHIVE="$TEMP_DIR/docker.tgz"
    DOCKER_EXTRACT_DIR="$TEMP_DIR/docker-extract"
    mkdir -p "$DOCKER_EXTRACT_DIR"
    download "$DOCKER_URL" "$DOCKER_ARCHIVE"
    tar -xzf "$DOCKER_ARCHIVE" -C "$DOCKER_EXTRACT_DIR"

    [[ -x "$DOCKER_EXTRACT_DIR/docker/docker" ]] \
        || fail "The Docker archive does not contain the docker client."
    [[ -x "$DOCKER_EXTRACT_DIR/docker/dockerd" ]] \
        || fail "The Docker archive does not contain dockerd."

    docker_binaries=("$DOCKER_EXTRACT_DIR"/docker/*)
    [[ ${#docker_binaries[@]} -gt 0 ]] || fail "No Docker binaries found in archive."

    log "Installing Docker binaries into /usr/bin"
    for docker_binary in "${docker_binaries[@]}"; do
        [[ -f "$docker_binary" ]] || continue
        install -m 0755 "$docker_binary" "/usr/bin/$(basename "$docker_binary")"
    done
    DOCKER_CHANGED=true
fi

UNIT_CHANGED=false
if [[ ! -f "$DOCKER_UNIT" ]]; then
    log "Creating $DOCKER_UNIT (data-root=$DOCKER_DATA_ROOT)"
    install -d -m 0755 "$(dirname "$DOCKER_UNIT")"
    cat > "$DOCKER_UNIT" <<EOF
[Unit]
Description=Docker Application Container Engine
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/dockerd --data-root=$DOCKER_DATA_ROOT
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
    UNIT_CHANGED=true
else
    log "$DOCKER_UNIT already exists; keeping its current configuration."
fi

install -d -m 0755 "$DOCKER_DATA_ROOT"

if [[ "$UNIT_CHANGED" == "true" ]]; then
    systemctl daemon-reload
fi
systemctl enable docker.service >/dev/null

if [[ "$DOCKER_CHANGED" == "true" ]] && systemctl is-active docker.service >/dev/null 2>&1; then
    log "Restarting Docker service after binary update."
    systemctl restart docker.service
elif ! systemctl is-active docker.service >/dev/null 2>&1; then
    log "Starting Docker service."
    systemctl start docker.service
else
    log "Docker service is already running."
fi

COMPOSE_VERSION_NUMBER="${COMPOSE_VERSION#v}"
if [[ "$FORCE" != "true" ]] \
    && [[ -x "$COMPOSE_PLUGIN" ]] \
    && "$DOCKER_BIN" compose version --short 2>/dev/null | grep -Fqx "$COMPOSE_VERSION_NUMBER"; then
    log "Docker Compose $COMPOSE_VERSION is already installed; skipping binary."
else
    COMPOSE_DOWNLOAD="$TEMP_DIR/docker-compose"
    download "$COMPOSE_URL" "$COMPOSE_DOWNLOAD"
    install -d -m 0755 "$COMPOSE_PLUGIN_DIR"
    install -m 0755 "$COMPOSE_DOWNLOAD" "$COMPOSE_PLUGIN"
fi

# Also expose the legacy command name for deployment scripts that still use it.
if [[ ! -e /usr/local/bin/docker-compose && ! -L /usr/local/bin/docker-compose ]]; then
    install -d -m 0755 /usr/local/bin
    ln -s "$COMPOSE_PLUGIN" /usr/local/bin/docker-compose
fi

log "Waiting for the Docker daemon to become ready."
daemon_ready=false
for _ in {1..30}; do
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
        daemon_ready=true
        break
    fi
    sleep 1
done
[[ "$daemon_ready" == "true" ]] \
    || fail "Docker service started but the daemon did not become ready. Check: journalctl -u docker"

log "Installation complete."
"$DOCKER_BIN" --version
"$DOCKER_BIN" compose version
log "Docker data root: $("$DOCKER_BIN" info --format '{{.DockerRootDir}}')"
