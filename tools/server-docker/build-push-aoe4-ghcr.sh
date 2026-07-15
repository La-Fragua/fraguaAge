#!/usr/bin/env bash
# Build the single-container AoE IV: AE image with BattleServer.exe baked in and
# push it to GHCR. Run from anywhere; paths are resolved relative to the repo.
#
# This image contains proprietary game content. Keep the GHCR package PRIVATE.
#
# Prerequisites:
#   1. A copy of BattleServer.exe from your AoE IV installation.
#   2. Logged in to GHCR with a token that has write:packages, e.g.:
#        echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin
#
# Usage:
#   tools/server-docker/build-push-aoe4-ghcr.sh <path-to-BattleServer.exe> [tag]
#
# Examples:
#   tools/server-docker/build-push-aoe4-ghcr.sh ~/AoE4/BattleServer.exe
#   tools/server-docker/build-push-aoe4-ghcr.sh ~/AoE4/BattleServer.exe v1.0.0
#
# Environment overrides:
#   GHCR_OWNER   GHCR namespace (default: la-fragua)
#   IMAGE_NAME   image name     (default: fraguaage-aoe4)
#   PLATFORM     target platform(default: linux/amd64 - required for Wine)
set -euo pipefail

EXE_SRC="${1:-}"
TAG="${2:-latest}"
GHCR_OWNER="${GHCR_OWNER:-la-fragua}"
IMAGE_NAME="${IMAGE_NAME:-fraguaage-aoe4}"
PLATFORM="${PLATFORM:-linux/amd64}"

if [ -z "$EXE_SRC" ]; then
	echo "Usage: $0 <path-to-BattleServer.exe> [tag]" >&2
	exit 2
fi
if [ ! -f "$EXE_SRC" ]; then
	echo "ERROR: BattleServer.exe not found at: $EXE_SRC" >&2
	exit 1
fi

# Repo root = two levels up from this script (tools/server-docker/..).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CTX_EXE="$REPO_ROOT/tools/server-docker/Dockerfile/aoe4/BattleServer.exe"
DOCKERFILE="tools/server-docker/Dockerfile/aoe4/Dockerfile"
IMAGE="ghcr.io/${GHCR_OWNER}/${IMAGE_NAME}"

# Stage the exe into the build context (gitignored) and clean it up on exit.
cp "$EXE_SRC" "$CTX_EXE"
cleanup() { rm -f "$CTX_EXE"; }
trap cleanup EXIT

TAGS=(-t "${IMAGE}:${TAG}")
if [ "$TAG" != "latest" ]; then
	TAGS+=(-t "${IMAGE}:latest")
fi

echo "Building ${IMAGE}:${TAG} (${PLATFORM}) with BattleServer.exe baked in..."
cd "$REPO_ROOT"
docker buildx build \
	--platform "$PLATFORM" \
	-f "$DOCKERFILE" \
	"${TAGS[@]}" \
	--push \
	.

echo
echo "Pushed ${IMAGE}:${TAG}"
echo "Run it on a Linux amd64 host:"
echo "  docker run -d --name aoe4 --network host \\"
echo "    -v aoe4_certs:/app/server/resources/certificates \\"
echo "    ${IMAGE}:${TAG}"
echo
echo "Reminder: keep this GHCR package PRIVATE."
