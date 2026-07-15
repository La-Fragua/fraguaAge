#!/bin/sh
# Zero-config entrypoint for the AoE II: DE LAN server.
# Generates a self-signed certificate on first boot (idempotent) and starts
# the server with age2 enabled. No arguments or environment are required.
set -eu

GAME=age2
TS=$(date +"%Y-%m-%dT%H-%M-%S")

# Self-signed certificate. Written to resources/certificates next to the
# server binary. Regenerated only if not already present (volume-persisted).
./bin/genCert --ignoreIfExisting

# shellcheck disable=SC2086
exec ./server -e "$GAME" --log --flatLog \
	--logRoot="/app/logs/server/$GAME/$TS" ${SERVER_ARGS:-}
