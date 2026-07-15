#!/usr/bin/env bash
#
# connect-aoe2.sh - Join our Age of Empires II: DE LAN server (Linux).
#
# What it does:
#   1. Downloads the ageLANServer launcher (once, cached) for your CPU.
#   2. Runs preflight checks (network, firewall, Steam, game install,
#      /proc, certs, UDP, server health).
#   3. Points the game at our LAN server and launches AoE2 DE (with --log).
#   4. Post-launch: if the launcher fails, analyzes the log for known error
#      patterns and prints targeted fix suggestions.
#
# Run it as your NORMAL user (do NOT use sudo). When the launcher needs to edit
# /etc/hosts and trust the server's certificate, a polkit password prompt pops
# up for just those steps. Everything is reverted automatically when you quit.
#
# Requirements: Linux, Steam running with AoE2 DE installed (Proton enabled),
# and you must be on the same LAN (or VPN) as the server.
#
# Usage:
#   ./connect-aoe2.sh                   # check, then connect to the default server
#   ./connect-aoe2.sh 192.168.1.50      # connect to a specific server IP
#   ./connect-aoe2.sh --check           # run diagnostics only, do NOT launch
#   ./connect-aoe2.sh --fix-cacert      # manually inject the server CA cert
#                                        #   into the game (workaround for
#                                        #   "Failed to save CA / exit code 22")
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
ANNOUNCE_PORT=31978

CHECK_ONLY=0
FIX_CACERT=0
for a in "$@"; do
  case "$a" in
    --check|-c) CHECK_ONLY=1 ;;
    --fix-cacert) FIX_CACERT=1 ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
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
# Utilities
# ---------------------------------------------------------------------------
tcp_open() { timeout 5 bash -c ":</dev/tcp/$1/$2" >/dev/null 2>&1; }

lan_subnet() {
  local ip
  ip=$(ip route get "$SERVER_IP" 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
  [ -n "$ip" ] && echo "${ip%.*}.0/24"
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

find_game_path() {
  local d
  while IFS= read -r d; do
    local m="$d/steamapps/appmanifest_${STEAM_APPID}.acf"
    [ -f "$m" ] || continue
    local lp; lp=$(grep -oE '"installdir"\s*"[^"]*"' "$m" 2>/dev/null | head -1 | sed 's/.*"installdir"\s*"\([^"]*\)"/\1/')
    if [ -n "$lp" ]; then
      echo "$d/steamapps/common/$lp"
      return 0
    fi
    echo "$d/steamapps/common/AoE2DE"  # guess
    return 0
  done < <(steam_dirs)
  return 1
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
check_os_deps() {
  info "System & dependencies"
  [ "$(uname -s)" = "Linux" ] && ok "Linux ($(uname -m))" || fail "Not Linux - this script is Linux only."
  local d
  for d in curl tar; do command -v "$d" >/dev/null 2>&1 && ok "$d present" || fail "missing '$d'"; done
  if command -v pkexec >/dev/null 2>&1; then ok "pkexec (polkit) present"
  else warn "pkexec (polkit) not found"; hint "Install it so the launcher can elevate hosts/cert:  sudo apt install policykit-1"; fi
}

check_proc() {
  info "/proc filesystem (required for game detection)"
  if [ -d /proc ] && [ -r /proc/1/cmdline ]; then ok "/proc is accessible"
  else
    fail "/proc is not readable"
    hint "The launcher cannot detect when AoE2 starts or stops without /proc."
    hint "This is extremely unusual on a standard Linux install. Check that your"
    hint "kernel was built with CONFIG_PROC_FS=y and that no security module"
    hint "(AppArmor, SELinux, or a container) is blocking /proc access."
  fi
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

check_server_health() {
  info "Server health ($SERVER_IP)"
  local resp
  resp=$(curl -sk --connect-timeout 5 --max-time 10 "https://$SERVER_IP/test" 2>/dev/null || true)
  if [ -n "$resp" ]; then
    local sid; sid=$(curl -sk --connect-timeout 5 --max-time 10 -D- "https://$SERVER_IP/test" 2>/dev/null | grep -i 'x-id:' | tr -d '\r' | awk '{print $2}')
    local sver; sver=$(curl -sk --connect-timeout 5 --max-time 10 -D- "https://$SERVER_IP/test" 2>/dev/null | grep -i 'x-version:' | tr -d '\r' | awk '{print $2}')
    ok "Server responding: id=$sid version=$sver"
    if echo "$resp" | grep -q "$GAME"; then
      ok "Server is serving game '$GAME' (match)"
    else
      warn "Server game title ($(echo "$resp" | grep -o '"GameTitle":"[^"]*"' | cut -d'"' -f4)) may not match expected '$GAME'"
    fi
  else
    warn "Could not query /test on $SERVER_IP"
    hint "The server may be running but with a different TLS certificate, or curl"
    hint "could not verify the connection. This is not fatal if TCP 443 is reachable."
  fi
}

check_udp_port() {
  info "UDP announce port $ANNOUNCE_PORT (server discovery)"
  if command -v nc >/dev/null 2>&1; then
    if timeout 3 nc -z -u -w2 "$SERVER_IP" "$ANNOUNCE_PORT" 2>/dev/null; then
      ok "UDP $ANNOUNCE_PORT reachable (server discovery should work)"
    else
      warn "nc could not confirm UDP $ANNOUNCE_PORT"
      hint "UDP may be blocked or the server's announce port is different. With"
      hint "a warn but no fail on the TCP check, this is usually fine."
    fi
  else
    warn "nc (netcat) not available, skipping UDP check"
    hint "Install 'netcat-openbsd' for UDP diagnostics if you suspect firewall issues."
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
                        hint "Native Steam ('sudo apt install steam') is the most reliable for this launcher."
                        hint "On Arch-based distros, install 'steam' or 'steam-native-runtime' for native Steam." ;;
    esac
  else
    fail "Steam not found"
    hint "Install Steam and sign in before running this."
  fi

  if pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1; then ok "Steam is running"
  else warn "Steam does not appear to be running - open it and sign in first."; fi

  local handler=""
  command -v xdg-mime >/dev/null 2>&1 && handler=$(xdg-mime query default x-scheme-handler/steam 2>/dev/null || true)
  if [ -n "$handler" ]; then ok "steam:// handler registered ($handler)"
  else warn "No steam:// URL handler registered - the game may not launch."
       hint "Fix:  xdg-mime default steam.desktop x-scheme-handler/steam"; fi

  # Test if steam:// actually launches something (non-blocking probe)
  if command -v xdg-open >/dev/null 2>&1 && [ -n "$handler" ]; then
    # Launch in background, kill after a few seconds; we just want to know
    # if the command itself succeeds (exit 0) vs fails (non-zero / not found).
    if timeout 3 xdg-open "steam://open/main" >/dev/null 2>&1; then
      ok "steam:// URL handler test OK (Steam responded)"
    else
      warn "steam:// URL handler did not respond in time; the game launch may hang silently."
      hint "Try running manually:  xdg-open steam://rungameid/$STEAM_APPID"
      hint "If that does nothing, reinstall Steam or fix the MIME handler."
    fi
  fi
}

check_game() {
  info "AoE II: DE install (Steam appid $STEAM_APPID)"
  local found="" proton=""
  while IFS= read -r d; do
    [ -f "$d/steamapps/appmanifest_${STEAM_APPID}.acf" ] && found="$d/steamapps"
    [ -d "$d/steamapps/compatdata/${STEAM_APPID}" ] && proton="$d/steamapps/compatdata/${STEAM_APPID}"
  done < <(steam_dirs)
  if [ -n "$found" ]; then ok "Game installed ($found)"
  else warn "appmanifest_${STEAM_APPID}.acf not found in the usual libraries."
       hint "If AoE2 DE is on another drive/library this may be a false alarm. Otherwise install it."; fi
  if [ -n "$proton" ]; then
    ok "Proton prefix exists (game has run via Proton before)"
    local pfver; pfver=$(cat "$proton/version" 2>/dev/null || echo "?")
    hint "  Prefix Proton version: $pfver"
  else warn "No Proton prefix for AoE2 DE yet."
       hint "In Steam: right-click AoE2 DE > Properties > Compatibility > 'Force Proton', then launch it once normally."; fi
}

check_certs() {
  info "Certificate store readiness"
  local game_path; game_path=$(find_game_path)
  if [ -z "$game_path" ]; then
    warn "Game path not found; skipping certificate checks."
    return
  fi
  local cert_dir="$game_path/certificates"
  if [ -d "$cert_dir" ]; then ok "Game certificate directory exists ($cert_dir)"
  else
    warn "Game certificate directory not found at $cert_dir"
    hint "This may cause 'Failed to save CA certificate to game' errors."
    hint "Expected: $cert_dir"
    return
  fi
  if [ -w "$cert_dir" ] && [ -f "$cert_dir/cacert.pem" ] && [ -w "$cert_dir/cacert.pem" ]; then
    ok "Game cacert.pem is writable"
  else
    warn "Game cacert.pem may not be writable"
    if [ -f "$cert_dir/cacert.pem" ]; then
      hint "Permissions: $(stat -c '%a %U:%G' "$cert_dir/cacert.pem" 2>/dev/null || ls -la "$cert_dir/cacert.pem")"
    fi
    hint "If the launcher fails with 'Failed to save CA certificate / exit code 22',"
    hint "run:  ./connect-aoe2.sh --fix-cacert"
  fi
  hint "Info: agent watches for process: AoE2DE_s.exe (in /proc/*/cmdline)"
}

# ---------------------------------------------------------------------------
# --fix-cacert mode: manual CA cert injection
# ---------------------------------------------------------------------------
do_fix_cacert() {
  info "--- Manual CA certificate injection ---"
  info "This bypasses the launcher's config-admin and writes the server's"
  info "CA cert directly into the game's cacert.pem using OpenSSL."

  local game_path; game_path=$(find_game_path)
  if [ -z "$game_path" ]; then
    die "Could not find AoE2 DE installation."; fi
  local cacert="$game_path/certificates/cacert.pem"
  if [ ! -f "$cacert" ]; then die "cacert.pem not found at $cacert"; fi
  ok "Found: $cacert"

  local tmp_cert; tmp_cert=$(mktemp)
  trap 'rm -f "$tmp_cert"' RETURN
  info "Fetching server certificate..."
  if ! timeout 10 openssl s_client -connect "${SERVER_IP}:443" -servername aoe-api.reliclink.com </dev/null 2>/dev/null | \
       openssl x509 -outform PEM > "$tmp_cert" 2>/dev/null; then
    die "Failed to fetch certificate from $SERVER_IP:443. Is the server running?"
  fi
  if [ ! -s "$tmp_cert" ]; then die "Empty certificate received."; fi
  ok "Certificate fetched ($(wc -l < "$tmp_cert") lines)"

  # Check if already in cacert.pem
  local fp; fp=$(openssl x509 -in "$tmp_cert" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')
  if grep -qi "$fp" "$cacert" 2>/dev/null; then
    ok "Certificate already present in game store."
    return 0
  fi

  info "Backing up original cacert.pem → cacert.pem.bak"
  cp "$cacert" "$game_path/certificates/cacert.pem.bak"

  info "Appending server certificate..."
  cat "$tmp_cert" >> "$cacert"
  ok "Certificate appended to $cacert"

  # Validate
  if openssl crl2pkcs7 -nocrl -certfile "$cacert" 2>/dev/null | openssl pkcs7 -print_certs -text -noout >/dev/null 2>&1; then
    ok "cacert.pem is valid after update"
  else
    warn "cacert.pem validation failed; restoring backup"
    mv "$game_path/certificates/cacert.pem.bak" "$cacert"
    die "Manual cert injection failed. Please report this."
  fi
  echo
  ok "Done. Now run ./connect-aoe2.sh normally."
  exit 0
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
# Post-launch log analyzer
# ---------------------------------------------------------------------------
analyze_logs() {
  local logdir="$1" rc="$2"
  [ -z "$logdir" ] && return

  info "Analyzing launcher logs..."
  local logs; logs=$(find "$logdir" -type f -name '*.txt' 2>/dev/null || true)
  [ -z "$logs" ] && { hint "No log files found."; return; }

  echo

  # Exit code 22 = ErrMissingLocalCertData
  if grep -q 'Exit code: 22' $logs 2>/dev/null || grep -q 'Failed to save CA certificate' $logs 2>/dev/null; then
    warn "Detected: 'Failed to save CA certificate' (exit code 22)"
    hint "This is a known issue on Arch-based distros (CachyOS, EndeavourOS,"
    hint "Manjaro) where the config-admin-agent fails to pass the certificate"
    hint "to the privileged helper. Fixed in later upstream releases."
    hint ""
    hint "WORKAROUND: Inject the cert manually before launching:"
    hint "  ./connect-aoe2.sh --fix-cacert"
    hint ""
    hint "Then run:  ./connect-aoe2.sh  (normal launch)"
    echo
  fi

  # Game never started
  if grep -q 'Failed to find the game' $logs 2>/dev/null; then
    warn "Detected: 'Failed to find the game'"
    hint "The launcher sent steam://rungameid/$STEAM_APPID but the AoE2 process"
    hint "(AoE2DE_s.exe) never appeared in /proc/*/cmdline within 60 seconds."
    hint ""
    hint "Possible causes:"
    hint "  1. Steam is Flatpak/Snap → the steam:// URL handler is broken."
    hint "     Fix: install native Steam ('sudo apt install steam' or pacman -S steam)."
    hint "  2. Proton/Wine took >60s to cold-start. The agent only waits 1 minute."
    hint "     Fix: launch AoE2 DE normally via Steam BEFORE running this script."
    hint "  3. The xdg-open steam:// command succeeded but Steam ignored it."
    hint "     Fix: run 'xdg-open steam://rungameid/$STEAM_APPID' manually to test."
    hint "  4. Your user cannot read /proc/*/cmdline (unlikely; check 'cat /proc/1/cmdline')."
    echo
  fi

  # Checksum mismatch (cross-platform lobbies invisible)
  # The launcher log won't show this directly, but server logs would.
  # We'll flag it as a general note on every Linux run.
  hint "Note: Linux (Proton) ↔ Windows cross-platform lobbies may not show up"
  hint "for each other due to AppBinaryChecksum / DataChecksum mismatches."
  hint "Both players MUST be on the exact same game version. To help debug,"
  hint "compare checksums from the server log if lobbies are invisible."
  echo

  # Check for agent log specifically
  local agent_log; agent_log=$(find "$logdir" -name 'agent.txt' 2>/dev/null | head -1)
  if [ -n "$agent_log" ]; then
    if grep -q 'Failed to find the game' "$agent_log"; then
      hint "Agent log ($agent_log):"
      hint "  The agent watches /proc/*/cmdline for 'AoE2DE_s.exe'."
      hint "  If you see this but the game DID start, the process name might differ."
      hint "  Check with:  pgrep -af AoE2DE_s || pgrep -af Age"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
run_checks() {
  echo
  check_os_deps
  check_proc
  check_network
  check_server_health
  check_udp_port
  check_firewall
  check_steam
  check_game
  check_certs
  echo
  if [ "$FAILS" -gt 0 ]; then printf '%sSummary: %d failure(s), %d warning(s).%s\n' "$c_err" "$FAILS" "$WARNS" "$c_off"
  elif [ "$WARNS" -gt 0 ]; then printf '%sSummary: %d warning(s) - review the hints above.%s\n' "$c_warn" "$WARNS" "$c_off"
  else printf '%sSummary: all checks passed.%s\n' "$c_ok" "$c_off"; fi
  echo
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if [ "$FIX_CACERT" -eq 1 ]; then
  do_fix_cacert
fi

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
  analyze_logs "$LOGDIR" "$rc"
  exit "$rc"
fi
[ -n "$LOGDIR" ] && hint "Detailed log (if you need it): $LOGDIR"
