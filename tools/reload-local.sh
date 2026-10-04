#!/usr/bin/env bash
# Rebuild the local T3 Code build and reinstall it into /Applications (install from Terminal.app,
# never inside T3 Code; tools/install-built-app.sh refuses there).
# Personal file: lives on features/tiliakoos only, never in a PR diff.
# Usage: tools/reload-local.sh [--no-install]
set -euo pipefail

cd "$(dirname "$0")/.."

# Node 24 (engines ^24.13.1, no .nvmrc); nvm misbehaves under `set -u`
set +u
export NVM_DIR="$HOME/.nvm"
. /opt/homebrew/opt/nvm/nvm.sh
nvm use 24 >/dev/null
set -u
export PATH="$HOME/.local/share/vite-plus/bin:$PATH"

# Xcode 26.6's linker can't read the macOS 27 CLT SDK that clang picks by default; pin Xcode's own SDK.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

# Without an update repository the build ships no app-update.yml, so it never updates itself.
unset GITHUB_REPOSITORY T3CODE_DESKTOP_UPDATE_REPOSITORY

IDENTITY="T3 Code Self-Signed"
TAG=$(git tag --merged HEAD -l 'v*-nightly.*' | sort -V | tail -1)
VERSION=${TAG#v}
OUT=release/local

# CI=true: pnpm can't ask before recreating node_modules without a terminal, and aborts instead.
# Scoped to this command only; electron-builder changes its publish behaviour when it sees CI.
CI=true vp i
rm -rf "$OUT"
node scripts/build-desktop-artifact.ts --platform mac --target zip --arch arm64 \
  --build-version "$VERSION" --output-dir "$OUT"

ditto -x -k "$OUT"/T3-Code-*-arm64.zip "$OUT/app"
APP=$(ls -d "$OUT"/app/*.app)
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [ "${1:-}" = "--no-install" ]; then
  echo "built $VERSION from $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD): $APP"
  exit 0
fi

tools/install-built-app.sh --yes
echo "installed $VERSION from $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
