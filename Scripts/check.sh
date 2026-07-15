#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

xcrun swift-format lint --strict --recursive --configuration .swift-format Sources Tests
# CodexClient tests launch stdio child processes, so serialize them to avoid teardown races.
xcrun swift test --no-parallel
