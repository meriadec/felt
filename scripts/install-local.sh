#!/usr/bin/env bash
# Install the current tree as the user's `felt` (ReleaseFast, prefix ~/.local),
# so the real binary always matches the code. Run it after every change:
# `zig build local`. The post-commit hook (.githooks/post-commit) runs it too.
set -euo pipefail
cd "$(dirname "$0")/.."
mise exec -- zig build -Doptimize=ReleaseFast --prefix "${FELT_PREFIX:-$HOME/.local}" install
echo "installed $(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo '+dirty') -> ${FELT_PREFIX:-$HOME/.local}/bin/felt"
