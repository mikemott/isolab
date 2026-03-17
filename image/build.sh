#!/bin/bash
# Build the isolab Docker image
# Copies Forge source into the build context before building
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORGE_SRC="${FORGE_SRC:-${HOME}/.local/share/forge}"

echo "isolab: preparing build context..."

# Copy forge into build context (exclude node_modules, dist — will rebuild in container)
rm -rf "${SCRIPT_DIR}/forge"
mkdir -p "${SCRIPT_DIR}/forge"

rsync -a --exclude='node_modules' --exclude='dist' --exclude='.git' \
    "${FORGE_SRC}/" "${SCRIPT_DIR}/forge/"

echo "isolab: building image..."
docker build -t isolab:latest "${SCRIPT_DIR}" "$@"

# Clean up
rm -rf "${SCRIPT_DIR}/forge"

echo "isolab: build complete"
