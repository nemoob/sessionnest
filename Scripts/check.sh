#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swiftpm-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

xcrun swift-format lint --strict --recursive --configuration .swift-format Sources Tests
# CodexClient tests launch stdio child processes, so serialize them to avoid teardown races.
SWIFT_TEST_OPTIONS=(--no-parallel)
# Nested macOS sandboxes are unavailable in some CI/agent environments.
if ! /usr/bin/sandbox-exec -p '(version 1) (allow default)' /usr/bin/true 2>/dev/null; then
  SWIFT_TEST_OPTIONS=(--disable-sandbox "${SWIFT_TEST_OPTIONS[@]}")
fi
xcrun swift test "${SWIFT_TEST_OPTIONS[@]}"
