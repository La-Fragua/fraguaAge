#!/usr/bin/env bash
#
# connect-aoe2.sh - Join our Age of Empires II: DE LAN server (Linux).
#
# What it does:
#   1. Downloads the ageLANServer launcher (once, cached) for your CPU.
#   2. Runs preflight checks (network, firewall, Steam, game install).
#   3. Points the game at our LAN server and launches AoE2 DE (with --log).
#
# Run it as your NORMAL user (do NOT use sudo). When the launcher needs to edit
# /etc/hosts and trust the server's certificate, a polkit password prompt pops
# up for just those steps. Everything is reverted automatically when you quit.
#
# Requirements: Linux, Steam running with AoE2 DE installed (Proton enabled),
# and you must be on the same LAN (or VPN) as the server.
#
# Usage:
#   ./connect-aoe2.sh                  # check, then connect to the default server
#   ./connect-aoe2.sh 192.168.1.50     # connect to a specific server IP
#   ./connect-aoe2.sh --check          # run diagnostics only, do NOT launch
#   SERVER_IP=10.0.0.5 ./connect-aoe2.sh
#
set -euo pipefail

# ===================== EDIT ME: default server address =====================
SERVER_IP="${SERVER_IP:-192.168.0.127}"
# ===========================================================================

GAME="age2"
STEAM_APPID="813780"                              # AoE II: DE
UPSTREAM_REPO="luskaner/ageLANServer"
LAUNCHER_VERSION="${LAUNCHER_VERSION:-latest}"    # or pin e.g. LAUNCHER_VERSION=v1.2.3
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/agelanserver"

CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --check|-c) CHECK_ONLY=1 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    -*)         : ;;                              # ignore unknown flags
    *)          SERVER_IP="$a" ;;                 # positional = server IP
  esac
done

# --- pretty output + pass/warn/fail tracking ---
c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_cya=$'\033[1;36m'; c_off=$'\033[0m'
WARNS=0; FAILS=0
info() { printf '%s==>%s %s\n' "$c_cya" "$c_off" "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n'   "$c_ok"   "$c_off" "$*"; }
warn() { printf '  %s[warn]%s %s\n'   "$c_warn" "$c_off" "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  %s[FAIL]%s %s\n'   "$c_err"  "$c_off" "$*"; FAILS=$((FAILS+1)); }
hint() { printf '         %s%s%s\n'   "$c_dim"  "$*" "$c_off"; }
die()  { printf '%serror:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
tcp_open() { timeout 5 bash -c ":</dev/tcp/$1/$2" >/dev/null 2>&1; }

lan_subnet() {
  local ip
  ip=$(ip route get "$SERVER_IP" 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
  [ -n "$ip" ] && echo "${ip%.*}.0/24"
}

check_os_deps() {
  info "System & dependencies"
  [ "$(uname -s)" = "Linux" ] && ok "Linux ($(uname -m))" || fail "Not Linux - this script is Linux only."
  local d
  for d in curl tar; do command -v "$d" >/dev/null 2>&1 && ok "$d present" || fail "missing '$d'"; done
  if command -v pkexec >/dev/null 2>&1; then ok "pkexec (polkit) present"
  else warn "pkexec (polkit) not found"; hint "Install it so the launcher can elevate hosts/cert:  sudo apt install policykit-1"; fi
}

check_network() {
  info "Network reachability to server $SERVER_IP"
  if tcp_open "$SERVER_IP" 443; then ok "TCP 443 reachable (server is up and not firewalled off)"
  else
    fail "Cannot reach $SERVER_IP:443"
    hint "Is the server running and are you on the same LAN/VPN?"
    hint "Test from here:   ping -c1 $SERVER_IP    and    curl -k https://$SERVER_IP"
  fi
}

check_firewall() {
  info "Local firewall"
  local active="" sub; sub=$(lan_subnet)
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then active="ufw"; fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then active="${active:+$active, }firewalld"; fi
  if [ -z "$active" ]; then
    ok "No active ufw/firewalld detected"
  else
    warn "Active firewall: $active"
    hint "AoE2 multiplayer needs inbound LAN traffic (discovery + peer connections)."
    hint "Do NOT disable the whole firewall. Instead allow your LAN subnet:"
    if [ -n "$sub" ]; then hint "    sudo ufw allow from $sub comment 'AoE LAN'"
    else                   hint "    sudo ufw allow from <your-LAN-subnet e.g. 192.168.0.0/24> comment 'AoE LAN'"; fi
    hint "(firewalld:  sudo firewall-cmd --permanent --zone=trusted --add-source=${sub:-<subnet>} && sudo firewall-cmd --reload )"
  fi
}

steam_dirs() {
  printf '%s\n' \
    "$HOME/.steam/steam" \
    "$HOME/.local/share/Steam" \
    "$HOME/.steam/debian-installation" \
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
    "$HOME/snap/steam/common/.local/share/Steam"
}

check_steam() {
  info "Steam"
  local kind=""
  command -v steam >/dev/null 2>&1 && kind="native"
  flatpak list --app 2>/dev/null | grep -qi 'com.valvesoftware.Steam' && kind="${kind:+$kind+}flatpak"
  [ -d "$HOME/snap/steam" ] && kind="${kind:+$kind+}snap"
  if [ -n "$kind" ]; then
    ok "Steam detected: $kind"
    case "$kind" in
      *flatpak*|*snap*) warn "Sandboxed Steam (flatpak/snap) can break the 'steam://' launch used to start the game."
                        hint "Native Steam ('sudo apt install steam') is the most reliable for this launcher." ;;
    esac
  else
    fail "Steam not found"
    hint "Install Steam and sign in before running this."
  fi

  if pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1; then ok "Steam is running"
  else warn "Steam does not appear to be running - open it and sign in first."; fi

  # steam:// URL handler (the launcher starts the game via steam://rungameid/APPID)
  local handler=""
  command -v xdg-mime >/dev/null 2>&1 && handler=$(xdg-mime query default x-scheme-handler/steam 2>/dev/null || true)
  if [ -n "$handler" ]; then ok "steam:// handler registered ($handler)"
  else warn "No steam:// URL handler registered - the game may not launch."
       hint "Fix:  xdg-mime default steam.desktop x-scheme-handler/steam"; fi
}

check_game() {
  info "AoE II: DE install (Steam appid $STEAM_APPID)"
  local d found="" proton=""
  while IFS= read -r d; do
    [ -f "$d/steamapps/appmanifest_${STEAM_APPID}.acf" ] && found="$d/steamapps"
    [ -d "$d/steamapps/compatdata/${STEAM_APPID}" ] && proton="$d/steamapps/compatdata/${STEAM_APPID}"
  done < <(steam_dirs)
  if [ -n "$found" ]; then ok "Game installed ($found)"
  else warn "appmanifest_${STEAM_APPID}.acf not found in the usual libraries."
       hint "If AoE2 DE is on another drive/library this may be a false alarm. Otherwise install it."; fi
  if [ -n "$proton" ]; then ok "Proton prefix exists (game has run via Proton before)"
  else warn "No Proton prefix for AoE2 DE yet."
       hint "In Steam: right-click AoE2 DE > Properties > Compatibility > 'Force Proton', then launch it once normally."; fi
}

run_checks() {
  echo
  check_os_deps
  check_network
  check_firewall
  check_steam
  check_game
  echo
  if [ "$FAILS" -gt 0 ]; then printf '%sSummary: %d failure(s), %d warning(s).%s\n' "$c_err" "$FAILS" "$WARNS" "$c_off"
  elif [ "$WARNS" -gt 0 ]; then printf '%sSummary: %d warning(s) - review the hints above.%s\n' "$c_warn" "$WARNS" "$c_off"
  else printf '%sSummary: all checks passed.%s\n' "$c_ok" "$c_off"; fi
  echo
}

# ---------------------------------------------------------------------------
# Launcher download
# ---------------------------------------------------------------------------
get_launcher() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="x86-64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  api() { curl -fsSL -H "Accept: application/vnd.github+json" "$@"; }
  local TAG
  if [ "$LAUNCHER_VERSION" = "latest" ]; then
    TAG=$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)
    [ -n "$TAG" ] || die "Could not determine the latest release tag (GitHub API rate limit?)."
  else TAG="$LAUNCHER_VERSION"; fi
  local DEST="$CACHE_ROOT/$TAG-$ARCH"
  LAUNCHER_BIN="$DEST/launcher"
  if [ ! -x "$LAUNCHER_BIN" ]; then
    info "Downloading launcher $TAG for linux $ARCH..."
    local URL; URL=$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/$TAG" \
          | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | cut -d'"' -f4 \
          | grep -E "_launcher_.*_linux_${ARCH}\.tar\.gz$" | head -1)
    [ -n "$URL" ] || die "No launcher asset for linux $ARCH in release $TAG."
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    curl -fL --progress-bar "$URL" -o "$tmp/launcher.tar.gz" || die "Download failed."
    rm -rf "$DEST"; mkdir -p "$DEST"; tar xzf "$tmp/launcher.tar.gz" -C "$DEST"
    LAUNCHER_BIN=$(find "$DEST" -type f -name launcher | head -1)
    [ -n "$LAUNCHER_BIN" ] || die "launcher binary not found inside the archive."
    chmod +x "$LAUNCHER_BIN"
  fi
  LAUNCHER_DIR=$(dirname "$LAUNCHER_BIN")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
run_checks

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "Check-only mode: not launching. Re-run without --check to play."
  exit $([ "$FAILS" -gt 0 ] && echo 1 || echo 0)
fi

if [ "$FAILS" -gt 0 ]; then
  warn "There are failed checks above. Trying to launch anyway; if it doesn't work, fix them first."
fi

get_launcher
info "Connecting to AoE2 DE LAN server at $SERVER_IP ..."
info "A password prompt may appear (to edit hosts + trust the certificate)."
cd "$LAUNCHER_DIR"

set +e
./launcher -e "$GAME" -s "$SERVER_IP" --log
rc=$?
set -e

# Surface the launcher log so problems can be shared.
LOGDIR=$(find "$LAUNCHER_DIR/logs/$GAME" -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
if [ "$rc" -ne 0 ]; then
  warn "Launcher exited with code $rc."
  if [ -n "$LOGDIR" ]; then
    hint "Log folder: $LOGDIR"
    echo "----- last launcher log -----"
    find "$LOGDIR" -type f -name '*.txt' -exec tail -n 40 {} + 2>/dev/null || true
    echo "-----------------------------"
    hint "Share the lines above (or the whole $LOGDIR folder) to get help."
  fi
  exit "$rc"
fi
[ -n "$LOGDIR" ] && hint "Detailed log (if you need it): $LOGDIR"
