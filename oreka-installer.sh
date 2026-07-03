#!/usr/bin/env bash
#
# oreka-installer.sh — Build and install the Oreka VoIP recorder (orkaudio)
# from source, including its Opus and SILK codec dependencies.
#
# Tested on Debian/Ubuntu. Must be run as root (uses apt and installs into
# system directories under /usr/src, /opt and /usr/local).
#
# Usage:
#   ./oreka-installer.sh [install]     Build and install Oreka (default)
#   ./oreka-installer.sh uninstall     Remove Oreka, codecs and service unit
#   ./oreka-installer.sh --help        Show this help
#
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SRC_DIR="/usr/src"
OPUS_PREFIX="/opt/opus"
DEPS_REPO="https://github.com/OrecX/dependencies.git"
OREKA_REPO="https://github.com/talkkonnect/Oreka/"
OPUS_VERSION="opus-1.2.1"
LOG_FILE="/var/log/oreka-installer.log"
SERVICE_NAME="oreka"
SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

# ----------------------------------------------------------------------------
# Pretty logging helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()   { printf '%s %s[*]%s %s\n'  "$(_ts)" "$C_BLUE"   "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
ok()    { printf '%s %s[✓]%s %s\n'  "$(_ts)" "$C_GREEN"  "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
warn()  { printf '%s %s[!]%s %s\n'  "$(_ts)" "$C_YELLOW" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
err()   { printf '%s %s[✗]%s %s\n'  "$(_ts)" "$C_RED"    "$C_RESET" "$*" | tee -a "$LOG_FILE" >&2; }

step() {
    STEP=$((STEP + 1))
    printf '\n%s%s══ Step %d/%d: %s %s\n' "$C_BOLD" "$C_BLUE" "$STEP" "$TOTAL_STEPS" "$*" "$C_RESET" \
        | tee -a "$LOG_FILE"
}

STEP=0
TOTAL_STEPS=6

# ----------------------------------------------------------------------------
# Error / cleanup handling
# ----------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line=$1
    err "Installation failed at line ${line} (exit code ${exit_code})."
    err "See ${LOG_FILE} for the full log."
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Try: sudo $0"
        exit 1
    fi
}

# Run an apt operation non-interactively.
apt_do() { DEBIAN_FRONTEND=noninteractive apt-get -y "$@" >>"$LOG_FILE" 2>&1; }

# ----------------------------------------------------------------------------
# Installation steps
# ----------------------------------------------------------------------------
install_packages() {
    step "Installing system packages and build dependencies"

    log "Updating package index..."
    apt_do update
    ok "Package index updated."

    # Grouped for readability; installed in a single transaction so apt can
    # resolve everything together and we only hit the network once.
    local packages=(
        # Oreka / orkaudio core libraries
        libboost-dev libboost-system-dev libapr1-dev liblog4cxx-dev
        libpcap-dev libxerces-c-dev libsndfile1-dev libspeex-dev
        # Toolchain
        git build-essential autoconf libtool libtool-bin pkg-config cmake
        # Additional codec / support libraries
        uuid-dev libssl-dev libsqlite3-dev libcurl4-openssl-dev libldns-dev
        libspeexdsp-dev libedit-dev libtiff-dev libopus-dev liblua5.2-dev
        libpq-dev libsndfile-dev libpcre2-dev libavformat-dev libswscale-dev
        # Utilities used during/after the build
        net-tools curl
    )

    log "Installing ${#packages[@]} packages (this may take a while)..."
    apt_do install "${packages[@]}"
    ok "All build dependencies installed."
}

build_opus() {
    step "Building the Opus codec (static build)"

    cd "$SRC_DIR"
    if [[ -d "${SRC_DIR}/dependencies/.git" ]]; then
        log "Dependencies repo already present, refreshing..."
        git -C "${SRC_DIR}/dependencies" pull --ff-only >>"$LOG_FILE" 2>&1 || \
            warn "Could not fast-forward dependencies repo; using existing checkout."
    else
        log "Cloning dependency archive repo..."
        rm -rf "${SRC_DIR}/dependencies"
        git clone "$DEPS_REPO" >>"$LOG_FILE" 2>&1
    fi
    ok "Dependency archives ready."

    log "Extracting and configuring ${OPUS_VERSION}..."
    tar -xf "dependencies/${OPUS_VERSION}.tar.gz"
    cd "${SRC_DIR}/${OPUS_VERSION}"
    ./configure --prefix="$OPUS_PREFIX" >>"$LOG_FILE" 2>&1

    log "Compiling Opus (using $(nproc) cores)..."
    make -j"$(nproc)" CFLAGS="-fPIC -msse4.1" >>"$LOG_FILE" 2>&1
    make install >>"$LOG_FILE" 2>&1

    # Oreka links against a statically-named copy of the archive.
    cp "${OPUS_PREFIX}/lib/libopus.a" "${OPUS_PREFIX}/lib/libopusstatic.a"
    ok "Opus built and installed to ${OPUS_PREFIX}."
}

build_silk() {
    step "Building the SILK codec"

    log "Extracting SILK SDK to /opt..."
    tar -xf "${SRC_DIR}/dependencies/silk.tgz" -C /opt/

    log "Compiling SILK codec library..."
    cd /opt/silk/SILKCodec/SILK_SDK_SRC_FIX/
    make clean lib >>"$LOG_FILE" 2>&1
    ok "SILK codec built."
}

clone_oreka() {
    step "Fetching Oreka source"

    cd "$SRC_DIR"
    if [[ -d "${SRC_DIR}/Oreka/.git" ]]; then
        log "Oreka repo already present, refreshing..."
        git -C "${SRC_DIR}/Oreka" pull --ff-only >>"$LOG_FILE" 2>&1 || \
            warn "Could not fast-forward Oreka repo; using existing checkout."
    else
        log "Cloning Oreka from ${OREKA_REPO}..."
        rm -rf "${SRC_DIR}/Oreka"
        git clone "$OREKA_REPO" >>"$LOG_FILE" 2>&1
    fi
    ok "Oreka source ready at ${SRC_DIR}/Oreka."
}

# Configure, build and install one Oreka component (orkbasecxx / orkaudio).
build_oreka_component() {
    local component=$1
    log "Building ${component}..."
    cd "${SRC_DIR}/Oreka/${component}"
    autoreconf -i >>"$LOG_FILE" 2>&1
    ./configure CXX=g++ >>"$LOG_FILE" 2>&1
    make -j"$(nproc)" >>"$LOG_FILE" 2>&1
    make install >>"$LOG_FILE" 2>&1
    ok "${component} built and installed."
}

build_oreka() {
    step "Building and installing Oreka (orkbasecxx + orkaudio)"
    # orkbasecxx must be built and installed first — orkaudio links against it.
    build_oreka_component "orkbasecxx"
    build_oreka_component "orkaudio"
    ldconfig
    ok "Oreka installed."
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
# Remove a path if it exists, logging what happened.
remove_path() {
    local path=$1
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        ok "Removed ${path}"
    else
        log "Not present (skipping): ${path}"
    fi
}

stop_service() {
    step "Stopping and disabling the ${SERVICE_NAME} service"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true
        systemctl disable "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true
        remove_path "$SERVICE_UNIT"
        systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
        systemctl reset-failed "$SERVICE_NAME" >>"$LOG_FILE" 2>&1 || true
        ok "Service stopped and unit removed."
    else
        warn "systemctl not found; skipping service teardown."
    fi
}

remove_binaries() {
    step "Removing installed orkaudio / orkbasecxx artifacts"

    # Kill any lingering orkaudio process before we delete its binary.
    if pgrep -x orkaudio >/dev/null 2>&1; then
        log "Terminating running orkaudio process..."
        pkill -x orkaudio || true
        sleep 1
    fi

    # Binaries dropped by `make install` (default prefixes).
    local bin
    for bin in /usr/local/sbin/orkaudio /usr/sbin/orkaudio /usr/bin/orkaudio; do
        remove_path "$bin"
    done

    # orkbasecxx shared libraries / headers installed under /usr/local.
    log "Removing orkbase libraries and headers..."
    find /usr/local/lib -maxdepth 1 -name 'liborkbase*' -exec rm -rvf {} + >>"$LOG_FILE" 2>&1 || true
    remove_path /usr/local/include/orkbasecxx
    ldconfig || true
    ok "Binaries and libraries removed."
}

remove_sources_and_codecs() {
    step "Removing build trees and codec installs"
    remove_path "${SRC_DIR}/${OPUS_VERSION}"
    remove_path "${SRC_DIR}/dependencies"
    remove_path "${SRC_DIR}/Oreka"
    remove_path "$OPUS_PREFIX"
    remove_path "/opt/silk"
    ok "Sources and codecs removed."
}

uninstall() {
    require_root
    : >"$LOG_FILE" || { echo "Cannot write to $LOG_FILE"; exit 1; }

    printf '%s%s\n' "$C_BOLD" "==============================================="
    printf '  Oreka VoIP Recorder — Uninstaller\n'
    printf '===============================================%s\n' "$C_RESET"
    warn "This removes orkaudio, orkbasecxx, the Opus/SILK codecs and the"
    warn "${SERVICE_NAME} service. System apt packages are left installed."

    if [[ "${OREKA_FORCE:-}" != "1" && -t 0 ]]; then
        read -r -p "Proceed with uninstall? [y/N] " reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) log "Aborted by user."; exit 0 ;;
        esac
    fi

    TOTAL_STEPS=3
    STEP=0
    stop_service
    remove_binaries
    remove_sources_and_codecs

    printf '\n'
    ok "${C_BOLD}Oreka uninstalled.${C_RESET}"
    log "Note: apt build dependencies were not removed. To purge them, run"
    log "apt-get remove/autoremove for the packages listed in install_packages()."
}

usage() {
    cat <<EOF
Oreka VoIP Recorder installer

Usage: $0 [command]

Commands:
  install      Build and install Oreka from source (default if omitted)
  uninstall    Stop the service and remove Oreka, codecs and build trees
  --help, -h   Show this help

Environment:
  OREKA_FORCE=1  Skip the interactive confirmation prompt on uninstall
EOF
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
install() {
    require_root
    : >"$LOG_FILE" || { echo "Cannot write to $LOG_FILE"; exit 1; }

    printf '%s%s\n' "$C_BOLD" "==============================================="
    printf '  Oreka VoIP Recorder — Installer\n'
    printf '===============================================%s\n' "$C_RESET"
    log "Logging full output to ${LOG_FILE}"

    install_packages
    build_opus
    build_silk
    clone_oreka
    build_oreka

    step "Locating the installed orkaudio binary"
    local orkaudio_bin
    orkaudio_bin="$(command -v orkaudio || true)"
    if [[ -z "$orkaudio_bin" ]]; then
        # make install typically drops it under /usr/local/sbin or /usr/sbin
        orkaudio_bin="$(find /usr/local/sbin /usr/sbin /usr/bin -name orkaudio 2>/dev/null | head -n1 || true)"
    fi
    if [[ -n "$orkaudio_bin" ]]; then
        ok "orkaudio installed at: ${orkaudio_bin}"
    else
        warn "Could not locate the orkaudio binary automatically; check the build log."
    fi

    printf '\n'
    ok "${C_BOLD}Oreka installation completed successfully.${C_RESET}"
    log "Next steps:"
    log "  1. Review the orkaudio config (typically /etc/orkaudio/config.xml)."
    log "  2. Install the service unit:  cp oreka.service /etc/systemd/system/"
    log "  3. Enable and start it:       systemctl daemon-reload && systemctl enable --now oreka"
}

main() {
    case "${1:-install}" in
        install)          install ;;
        uninstall)        uninstall ;;
        -h|--help|help)   usage ;;
        *)
            err "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
