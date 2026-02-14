#!/usr/bin/env bash
# =============================================================================
# build.sh — Build the Ephemeral Browser Agent Docker image
#
# Usage:
#   ./scripts/build.sh                    # Build with default tag
#   ./scripts/build.sh --tag my-tag       # Build with custom tag
#   ./scripts/build.sh --no-cache         # Build without Docker cache
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="medfinder/browser-agent"
IMAGE_TAG="latest"
NO_CACHE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)      IMAGE_TAG="$2"; shift 2 ;;
        --no-cache) NO_CACHE="--no-cache"; shift ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "============================================"
echo " Building Ephemeral Browser Agent"
echo " Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "============================================"
echo ""

docker build \
    ${NO_CACHE} \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f "${REPO_ROOT}/container/Dockerfile" \
    "${REPO_ROOT}/container"

echo ""
echo "============================================"
echo " Build complete!"
echo " Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo " Image size:"
docker images "${IMAGE_NAME}:${IMAGE_TAG}" --format "  {{.Size}}"
echo ""
echo " Next steps:"
echo "   1. Run a test task:"
echo "      ./scripts/browser-task.sh run 'Search Google for browser-use' --wait"
echo "   2. Set up the reaper cron job:"
echo "      (crontab -l 2>/dev/null; echo '0 * * * * $(pwd)/scripts/reaper.sh >> /var/log/browser-reaper.log 2>&1') | crontab -"
echo "============================================"
