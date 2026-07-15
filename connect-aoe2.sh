#!/usr/bin/env bash
#
# connect-aoe2.sh - Join our Age of Empires II: DE LAN server (Linux).
#
# What it does:
#   1. Downloads the ageLANServer launcher (once, cached) for your CPU.
#   2. Points the game at our LAN server and launches AoE2 DE.
#
# Run it as your NORMAL user (do NOT use sudo). When the launcher needs to edit
# /etc/hosts and trust the server's certificate, a polkit password prompt pops
# up for just those steps. Everything is reverted automatically when you quit.
#
# Requirements: Linux, Steam running with AoE2 DE installed, and you must be on
# the same LAN (or VPN) as the server. Needs: curl, tar, and pkexec (polkit).
#
# Usage:
#   ./connect-aoe2.sh                  # connect to the default server below
#   ./connect-aoe2.sh 192.168.1.50     # connect to a specific server IP
#   SERVER_IP=10.0.0.5 ./connect-aoe2.sh
#
set -euo pipefail

# ===================== EDIT ME: default server address =====================
SERVER_IP="${SERVER_IP:-192.168.0.127}"
# ===========================================================================

GAME="age2"
UPSTREAM_REPO="luskaner/ageLANServer"
LAUNCHER_VERSION="${LAUNCHER_VERSION:-latest}"   # or pin e.g. LAUNCHER_VERSION=v1.2.3
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/agelanserver"

# First positional argument overrides the server IP.
[ "${1:-}" != "" ] && SERVER_IP="$1"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- OS and dependency checks ---
[ "$(uname -s)" = "Linux" ] || die "This script is for Linux. On Windows/macOS run the launcher's start script instead."
for dep in curl tar; do command -v "$dep" >/dev/null 2>&1 || die "Missing required command: $dep"; done
command -v pkexec >/dev/null 2>&1 || warn "pkexec (polkit) not found. The launcher may fail to elevate for hosts/cert changes - install the 'polkit' package."

# --- CPU architecture ---
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x86-64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

api() { curl -fsSL -H "Accept: application/vnd.github+json" "$@"; }

# --- Resolve the release tag ---
if [ "$LAUNCHER_VERSION" = "latest" ]; then
  info "Finding the latest launcher release..."
  TAG=$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" \
        | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)
  [ -n "$TAG" ] || die "Could not determine the latest release tag (GitHub API rate limit?)."
else
  TAG="$LAUNCHER_VERSION"
fi

DEST="$CACHE_ROOT/$TAG-$ARCH"
LAUNCHER_BIN="$DEST/launcher"

# --- Download and extract the launcher if not already cached ---
if [ ! -x "$LAUNCHER_BIN" ]; then
  info "Downloading launcher $TAG for linux $ARCH..."
  URL=$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/$TAG" \
        | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | cut -d'"' -f4 \
        | grep -E "_launcher_.*_linux_${ARCH}\.tar\.gz$" | head -1)
  [ -n "$URL" ] || die "No launcher asset for linux $ARCH in release $TAG."
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fL --progress-bar "$URL" -o "$tmp/launcher.tar.gz" || die "Download failed."
  rm -rf "$DEST"; mkdir -p "$DEST"
  tar xzf "$tmp/launcher.tar.gz" -C "$DEST"
  found=$(find "$DEST" -type f -name launcher | head -1)
  [ -n "$found" ] || die "launcher binary not found inside the archive."
  LAUNCHER_BIN="$found"
  chmod +x "$LAUNCHER_BIN"
fi

LAUNCHER_DIR=$(dirname "$LAUNCHER_BIN")

# --- Friendly reachability check (non-fatal) ---
if ! curl -k -s -o /dev/null --connect-timeout 5 "https://$SERVER_IP:443/"; then
  warn "Can't reach https://$SERVER_IP:443 - are you on the LAN/VPN and is the server running?"
fi

info "Connecting to AoE2 DE LAN server at $SERVER_IP ..."
info "A password prompt may appear so it can edit hosts and trust the certificate."
cd "$LAUNCHER_DIR"
exec ./launcher -e "$GAME" -s "$SERVER_IP"
