#!/usr/bin/env bash
#
# connect-aoe2-mac.sh - Join our Age of Empires II: DE LAN server (macOS).
#
# What it does:
#   1. Downloads the ageLANServer launcher (v1.15.0-rc.1+, cached) for macOS.
#   2. Runs preflight checks (network, firewall, Steam, game install).
#   3. Points the game at our LAN server and launches AoE2 DE natively.
#   4. Everything is reverted automatically when you quit the game.
#
# AoE2 DE is now NATIVE on macOS (Feral Interactive port). No Crossover or
# Wine needed — it runs through Steam directly as a macOS .app bundle.
#
# Requirements: macOS 12+, Steam running with AoE2 DE installed.
#
# Usage:
#   ./connect-aoe2-mac.sh                    # check, then connect
#   ./connect-aoe2-mac.sh 192.168.1.50       # connect to a specific server IP
#   ./connect-aoe2-mac.sh --check            # diagnostics only, do NOT launch
#   ./connect-aoe2-mac.sh --diagnose-game    # deep dive: check process detection
#   ./connect-aoe2-mac.sh --fix-cacert       # manually inject the server CA cert
#
set -euo pipefail

# ===================== EDIT ME: default server address =====================
SERVER_IP="${SERVER_IP:-192.168.0.127}"
# ===========================================================================

GAME="age2"
STEAM_APPID="813780"
UPSTREAM_REPO="luskaner/ageLANServer"
# Pin to 1.15.0-rc.1 (first release with macOS launcher + native AoE2 support)
LAUNCHER_VERSION="${LAUNCHER_VERSION:-v1.15.0-rc.1}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/agelanserver"
ANNOUNCE_PORT=31978

CHECK_ONLY=0
FIX_CACERT=0
DIAGNOSE_GAME=0
for a in "$@"; do
  case "$a" in
    --check|-c)        CHECK_ONLY=1 ;;
    --fix-cacert)      FIX_CACERT=1 ;;
    --diagnose-game)   DIAGNOSE_GAME=1 ;;
    -h|--help)         sed -n '2,32p' "$0"; exit 0 ;;
    -*)                : ;;
    *)                 SERVER_IP="$a" ;;
  esac
done

# --- pretty output ---
c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_cya=$'\033[1;36m'; c_off=$'\033[0m'
WARNS=0; FAILS=0
info() { printf '%s==>%s %s\n' "$c_cya" "$c_off" "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n'   "$c_ok"   "$c_off" "$*"; }
warn() { printf '  %s[warn]%s %s\n'   "$c_warn" "$c_off" "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  %s[FAIL]%s %s\n'   "$c_err"  "$c_off" "$*"; FAILS=$((FAILS+1)); }
hint() { printf '         %s%s%s\n'   "$c_dim"  "$*" "$c_off"; }
die()  { printf '%serror:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
tcp_open() { timeout 5 bash -c ":</dev/tcp/$1/$2" >/dev/null 2>&1; }

lan_subnet() {
  local ip
  ip=$(route -n get "$SERVER_IP" 2>/dev/null | grep -E '^\s+interface' | head -1 || true)
  if [ -z "$ip" ]; then
    ip=$(ifconfig | grep -B1 "$SERVER_IP" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
  fi
  [ -n "$ip" ] && echo "${ip%.*}.0/24"
}

STEAM_BASE="$HOME/Library/Application Support/Steam"
GAME_BASE="$STEAM_BASE/steamapps/common/AoE2DE"
GAME_CERT_DIR="$GAME_BASE/AgeOfEmpires2Data/certificates"
GAME_APP="$GAME_BASE/Age Of Empires II.app"

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
check_os_deps() {
  info "System & dependencies"
  [ "$(uname -s)" = "Darwin" ] && ok "macOS ($(uname -m))" || fail "Not macOS - use connect-aoe2.sh for Linux."
  local d
  for d in curl tar; do command -v "$d" >/dev/null 2>&1 && ok "$d present" || fail "missing '$d'"; done
  # macOS version check
  local ver; ver=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
  if [ "${ver:-0}" -ge 12 ]; then ok "macOS ${ver}+ (Monterey or newer)"
  else warn "macOS ${ver} — may be too old for the launcher. Minimum: Monterey (12)."; fi
}

check_network() {
  info "Network reachability to server $SERVER_IP"
  if tcp_open "$SERVER_IP" 443; then ok "TCP 443 reachable (server is up)"
  else
    fail "Cannot reach $SERVER_IP:443"
    hint "Is the server running and are you on the same LAN/VPN?"
    hint "Test:  ping -c1 $SERVER_IP   or   curl -k https://$SERVER_IP"
  fi
}

check_server_health() {
  info "Server health ($SERVER_IP)"
  local resp
  resp=$(curl -sk --connect-timeout 5 --max-time 10 "https://$SERVER_IP/test" 2>/dev/null || true)
  if [ -n "$resp" ]; then
    local sid; sid=$(curl -sk --connect-timeout 5 --max-time 10 -D- "https://$SERVER_IP/test" 2>/dev/null | grep -i 'x-id:' | tr -d '\r' | awk '{print $2}')
    ok "Server responding: id=$sid"
    if echo "$resp" | grep -q "$GAME"; then
      ok "Server is serving game '$GAME' (match)"
    else
      warn "Server game title may not match expected '$GAME'"
    fi
  else
    warn "Could not query /test on $SERVER_IP"
  fi
}

check_firewall() {
  info "macOS firewall"
  local fw; fw=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)
  if echo "$fw" | grep -qi "Firewall is enabled"; then
    warn "macOS firewall is enabled."
    hint "If the server can't reach you, allow Steam and AoE2 DE in:"
    hint "  System Settings > Network > Firewall > Options"
    hint "  Ensure 'Automatically allow built-in software' is ON, or add Steam."
  else
    ok "macOS firewall is disabled (or not blocking)."
  fi
}

check_steam() {
  info "Steam"
  local steam_app="$HOME/Applications/Steam.app"
  [ ! -d "$steam_app" ] && steam_app="/Applications/Steam.app"
  if [ -d "$steam_app" ]; then ok "Steam.app found ($steam_app)"
  else
    fail "Steam.app not found in /Applications or ~/Applications."
    hint "Install Steam from https://store.steampowered.com/about/"
    return
  fi

  if pgrep -qi steam 2>/dev/null; then ok "Steam is running"
  else warn "Steam does not appear to be running — open it and sign in first."; fi

  # macOS doesn't use xdg-open; the launcher uses 'open' command
  if command -v open >/dev/null 2>&1; then
    ok "'open' command available (launcher will use: open steam://rungameid/$STEAM_APPID)"
  else
    fail "'open' command missing — this is a core macOS tool."
  fi
}

check_game() {
  info "AoE II: DE native macOS install (Steam appid $STEAM_APPID)"
  if [ -f "$STEAM_BASE/steamapps/appmanifest_${STEAM_APPID}.acf" ]; then
    ok "Game installed ($STEAM_BASE/steamapps)"
  else
    warn "appmanifest_${STEAM_APPID}.acf not found."
    hint "Install AoE2 DE via Steam on this Mac. It's available natively."
  fi
  if [ -d "$GAME_APP" ]; then
    ok "Native app bundle found: $GAME_APP"
  else
    warn "Native .app bundle not found at expected path."
    hint "Expected: $GAME_APP"
  fi
  if [ -d "$GAME_CERT_DIR" ]; then
    ok "Certificate directory exists ($GAME_CERT_DIR)"
  else
    warn "Certificate directory not found at $GAME_CERT_DIR"
  fi
  if [ -f "$GAME_CERT_DIR/cacert.pem" ]; then
    ok "Game cacert.pem found"
    if [ -w "$GAME_CERT_DIR/cacert.pem" ]; then ok "cacert.pem is writable"
    else warn "cacert.pem is not writable — cert injection may fail."; fi
  else
    warn "cacert.pem not found at $GAME_CERT_DIR"
    hint "Launch AoE2 DE from Steam at least once to create it."
  fi

  # Upstream bug: NativeMacOsGame() does executer.(steam.Exec) but the
  # actual type is *steam.Exec (pointer). This causes the launcher to
  # look for cacert.pem at .../AoE2DE/certificates/ instead of
  # .../AoE2DE/AgeOfEmpires2Data/certificates/. Work around by copying.
  local legacy_cert_dir="$GAME_BASE/certificates"
  if [ -f "$GAME_CERT_DIR/cacert.pem" ] && [ ! -f "$legacy_cert_dir/cacert.pem" ]; then
    warn "Known upstream bug: launcher looks for cacert.pem in wrong path."
    hint "Creating workaround copy at: $legacy_cert_dir"
    mkdir -p "$legacy_cert_dir"
    cp "$GAME_CERT_DIR/cacert.pem" "$legacy_cert_dir/cacert.pem"
    ok "Copy created: launcher can now find cacert.pem"
  elif [ -f "$legacy_cert_dir/cacert.pem" ]; then
    ok "Workaround cacert.pem already present at legacy path"
  fi
  hint "Agent watches for process: 'Age Of Empires II' (native macOS)"
}

# ---------------------------------------------------------------------------
# --diagnose-game mode
# ---------------------------------------------------------------------------
do_diagnose_game() {
  info "--- Deep game detection diagnostic ---"
  echo

  info "Scanning processes for 'Age Of Empires II'..."
  local found; found=$(ps aux 2>/dev/null | grep -i "[A]ge Of Empires II" || true)
  if [ -n "$found" ]; then
    ok "Game process FOUND:"
    echo "$found" | while IFS= read -r line; do hint "  $line"; done
  else
    warn "Game process 'Age Of Empires II' NOT found."
    hint "Launch AoE2 DE from Steam to the main menu, then re-run this diagnostic."
  fi

  echo
  info "Key paths:"
  [ -d "$GAME_BASE" ] && ok "Game: $GAME_BASE" || warn "Game dir missing: $GAME_BASE"
  [ -d "$GAME_APP" ] && ok "App: $GAME_APP" || warn "App bundle missing: $GAME_APP"
  [ -f "$GAME_CERT_DIR/cacert.pem" ] && ok "cacert: $GAME_CERT_DIR/cacert.pem" || warn "cacert.pem missing"

  echo
  [ -n "$found" ] && ok "Game detection looks healthy." || warn "Launch the game and re-run."
  echo
  exit 0
}

# ---------------------------------------------------------------------------
# --fix-cacert mode: manual CA cert injection into game
# ---------------------------------------------------------------------------
do_fix_cacert() {
  info "--- Manual CA certificate injection (macOS) ---"

  local cacert="$GAME_CERT_DIR/cacert.pem"
  if [ ! -f "$cacert" ]; then die "cacert.pem not found at $cacert"; fi
  ok "Found: $cacert"

  local tmp_cert; tmp_cert=$(mktemp)
  trap 'rm -f "$tmp_cert"' RETURN
  info "Fetching server certificate..."
  if ! timeout 10 openssl s_client -connect "${SERVER_IP}:443" -servername aoe-api.reliclink.com </dev/null 2>/dev/null | \
       openssl x509 -outform PEM > "$tmp_cert" 2>/dev/null; then
    die "Failed to fetch certificate from $SERVER_IP:443."
  fi
  if [ ! -s "$tmp_cert" ]; then die "Empty certificate received."; fi
  ok "Certificate fetched ($(wc -l < "$tmp_cert") lines)"

  info "Backing up original cacert.pem → cacert.pem.bak"
  cp "$cacert" "$GAME_CERT_DIR/cacert.pem.bak"

  info "Appending server certificate..."
  cat "$tmp_cert" >> "$cacert"
  ok "Certificate appended."

  openssl crl2pkcs7 -nocrl -certfile "$cacert" 2>/dev/null | openssl pkcs7 -print_certs -text -noout >/dev/null 2>&1 && \
    ok "cacert.pem is valid after update" || { warn "Validation failed; restoring backup"; mv "$GAME_CERT_DIR/cacert.pem.bak" "$cacert"; die "Manual cert injection failed."; }

  # Also copy to legacy path (upstream pointer-value type assertion bug)
  local legacy="$GAME_BASE/certificates/cacert.pem"
  mkdir -p "$(dirname "$legacy")"
  cp "$cacert" "$legacy"
  ok "Also copied to: $legacy"

  ok "Done. Run ./connect-aoe2-mac.sh normally."
  exit 0
}

# ---------------------------------------------------------------------------
# Launcher download
# ---------------------------------------------------------------------------
get_launcher() {
  local ARCH
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="x86-64" ;;  # Intel Mac
    arm64|aarch64) ARCH="arm64" ;;   # Apple Silicon
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  api() { curl -fsSL -H "Accept: application/vnd.github+json" "$@"; }
  local TAG="$LAUNCHER_VERSION"
  local DEST="$CACHE_ROOT/$TAG-mac"
  LAUNCHER_BIN="$DEST/launcher"

  if [ ! -x "$LAUNCHER_BIN" ]; then
    info "Downloading launcher $TAG for macOS..."
    local URL; URL=$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/$TAG" \
          | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | cut -d'"' -f4 \
          | grep -E "_launcher_.*_mac\.tar\.gz$" | head -1)
    [ -n "$URL" ] || die "No macOS launcher asset in $TAG."
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    curl -fL --progress-bar "$URL" -o "$tmp/launcher.tar.gz" || die "Download failed."
    rm -rf "$DEST"; mkdir -p "$DEST"; tar xzf "$tmp/launcher.tar.gz" -C "$DEST"
    LAUNCHER_BIN=$(find "$DEST" -type f -name launcher | head -1)
    [ -n "$LAUNCHER_BIN" ] || die "launcher binary not found inside the archive."
    chmod +x "$LAUNCHER_BIN"
    ok "Launcher ready: $LAUNCHER_BIN"
  fi
  LAUNCHER_DIR=$(dirname "$LAUNCHER_BIN")
}

# ---------------------------------------------------------------------------
# Post-launch log analyzer
# ---------------------------------------------------------------------------
analyze_logs() {
  local logdir="$1" rc="$2"
  [ -z "$logdir" ] && return
  info "Analyzing launcher logs..."
  local logs; logs=$(find "$logdir" -type f -name '*.txt' 2>/dev/null || true)
  [ -z "$logs" ] && { hint "No log files found."; return; }
  echo

  if grep -q 'Exit code: 22' $logs 2>/dev/null || grep -q 'Failed to save CA certificate' $logs 2>/dev/null; then
    warn "Detected: 'Failed to save CA certificate' (exit code 22)"
    hint "Workaround:  ./connect-aoe2-mac.sh --fix-cacert"
    hint "Then run:     ./connect-aoe2-mac.sh"
  fi

  if grep -q 'Failed to find the game' $logs 2>/dev/null; then
    warn "Detected: 'Failed to find the game'"
    hint "The launcher couldn't detect 'Age Of Empires II' process."
    hint "Launch AoE2 DE from Steam BEFORE running the launcher."
    hint "Diagnostic:  ./connect-aoe2-mac.sh --diagnose-game"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
run_checks() {
  echo
  check_os_deps
  check_network
  check_server_health
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
# Entry point
# ---------------------------------------------------------------------------
if [ "$FIX_CACERT" -eq 1 ]; then do_fix_cacert; fi
if [ "$DIAGNOSE_GAME" -eq 1 ]; then do_diagnose_game; fi

run_checks

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "Check-only mode: not launching. Re-run without --check to play."
  exit $([ "$FAILS" -gt 0 ] && echo 1 || echo 0)
fi

if [ "$FAILS" -gt 0 ]; then
  warn "There are failed checks. Trying to launch anyway — fix them if it fails."
fi

get_launcher
info "Connecting to AoE2 DE LAN server at $SERVER_IP ..."
info "You may be asked for your password (to edit /etc/hosts and trust the cert)."
cd "$LAUNCHER_DIR"

set +e
./launcher -e "$GAME" -s "$SERVER_IP" --log
rc=$?
set -e

LOGDIR=$(find "$LAUNCHER_DIR/logs/$GAME" -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
if [ "$rc" -ne 0 ]; then
  warn "Launcher exited with code $rc."
  if [ -n "$LOGDIR" ]; then
    hint "Log folder: $LOGDIR"
    echo "----- last launcher log -----"
    find "$LOGDIR" -type f -name '*.txt' -exec tail -n 40 {} + 2>/dev/null || true
    echo "-----------------------------"
  fi
  analyze_logs "$LOGDIR" "$rc"
  exit "$rc"
fi
[ -n "$LOGDIR" ] && hint "Detailed log (if you need it): $LOGDIR"
