#!/usr/bin/env bash
# Builds and (by default) pushes a multi-arch (amd64+arm64) debug image
# (images/debug/Dockerfile) to docker.io/hriships/debug. Multi-arch
# matters here specifically: it's attached to pods via `kubectl debug`
# on whatever architecture the cluster's nodes actually run — built
# single-arch on an Apple Silicon Mac, it fails on amd64 nodes with
# "exec format error".
#
# Requires a working docker (with buildx) or podman CLI already logged
# in to docker.io (`docker login` / `podman login`).
#
# Usage:
#   ./build.sh              # multi-arch build + push :latest
#   ./build.sh v1            # multi-arch build + push :v1
#   ./build.sh v1 --no-push  # host-arch-only build, skip the push
set -euo pipefail

err() {
    echo "❌ $*" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="docker.io/hriships/debug"
TAG="${1:-latest}"
FULL_TAG="${IMAGE}:${TAG}"
PUSH=1
[[ "${2:-}" == "--no-push" ]] && PUSH=0
PLATFORMS="linux/amd64,linux/arm64"

# Prefer podman: a `docker` on PATH is sometimes just podman's own
# docker-compat shim (e.g. /opt/podman/bin/docker), which doesn't
# support buildx's --push — podman's own manifest-list commands are the
# reliable multi-arch path in that case. Real Docker installs (no
# podman present) still fall back to docker buildx correctly.
if command -v podman &>/dev/null; then
    ENGINE=podman
elif command -v docker &>/dev/null; then
    ENGINE=docker
else
    err "Need docker or podman on PATH"
    exit 1
fi

if [[ "$PUSH" -eq 0 ]]; then
    echo "⏳ Building ${FULL_TAG} for the local host arch only (--no-push) with ${ENGINE}..."
    "$ENGINE" build -t "$FULL_TAG" "$SCRIPT_DIR"
    echo "✅ Built ${FULL_TAG}"
    echo "ℹ️  Skipped push (--no-push) — single-arch, host only"
    exit 0
fi

echo "⏳ Building and pushing ${FULL_TAG} for ${PLATFORMS} with ${ENGINE}..."

if [[ "$ENGINE" == "docker" ]]; then
    docker buildx build --platform "$PLATFORMS" -t "$FULL_TAG" --push "$SCRIPT_DIR"
else
    podman manifest rm "$FULL_TAG" &>/dev/null || true
    podman manifest create "$FULL_TAG"
    podman build --platform "$PLATFORMS" --manifest "$FULL_TAG" "$SCRIPT_DIR"
    podman manifest push --all "$FULL_TAG" "docker://${FULL_TAG}"
fi
echo "✅ Built and pushed ${FULL_TAG} (${PLATFORMS})"
