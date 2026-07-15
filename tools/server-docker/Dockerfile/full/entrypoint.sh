#!/bin/sh
# Zero-config entrypoint for a single-container "full" LAN server (any game).
# Runs the whole stack:
#   1. generates a self-signed certificate (idempotent),
#   2. starts the battle-server-manager, which launches BattleServer.exe (Wine),
#   3. starts the game server with $GAME enabled,
#   4. supervises both and exits (so Docker restarts) if either dies.
#
# $GAME is baked in at build time (ENV GAME, from the --build-arg GAME).
# BattleServer.exe is baked in at build time. Host networking is recommended on
# Linux (--network host) so the game client can reach the battle server.
set -eu

GAME="${GAME:?GAME environment variable is not set (bake it via --build-arg GAME)}"
TS=$(date +"%Y-%m-%dT%H-%M-%S")
BATTLE_SERVER_EXE=/app/BattleServer.exe

if [ ! -f "$BATTLE_SERVER_EXE" ]; then
	echo "ERROR: $BATTLE_SERVER_EXE is missing from the image."
	echo "It must be baked in at build time (build-push-full-ghcr.sh)."
	exit 1
fi

# 1) Self-signed certificate (idempotent, volume-persisted).
(cd /app/server && ./bin/genCert --ignoreIfExisting)

# 2) Battle-server-manager. `start` launches BattleServer.exe under Wine and returns.
cd /app/battle-server-manager
./battle-server-manager clean
# shellcheck disable=SC2086
./battle-server-manager start --hideWindow -e "$GAME" \
	--logRoot="/app/logs/battle-server-manager/$GAME/$TS" ${BS_MANAGER_ARGS:-}

echo "Waiting for BattleServer.exe to come up..."
i=0
while ! pgrep -f BattleServer.exe > /dev/null; do
	i=$((i + 1))
	if [ "$i" -gt 60 ]; then
		echo "ERROR: BattleServer.exe did not start within 60s."
		exit 1
	fi
	sleep 1
done
echo "BattleServer.exe is up."

# 3) Game server (background so we can supervise alongside BattleServer.exe).
cd /app/server
# shellcheck disable=SC2086
./server -e "$GAME" --log --flatLog \
	--logRoot="/app/logs/server/$GAME/$TS" ${SERVER_ARGS:-} &
SERVER_PID=$!

# 4) Supervise. Forward termination, and exit non-zero if either component dies.
term() {
	kill "$SERVER_PID" 2>/dev/null || true
	exit 0
}
trap term TERM INT

while kill -0 "$SERVER_PID" 2>/dev/null && pgrep -f BattleServer.exe > /dev/null; do
	sleep 10
done

echo "A component stopped. Shutting down the container."
kill "$SERVER_PID" 2>/dev/null || true
exit 1
