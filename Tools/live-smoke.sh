#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ($# -eq 1 && "$1" != '--actions') ]]; then
    echo 'Usage: Tools/live-smoke.sh [--actions]' >&2
    exit 2
fi
mkdir -p .build/tools
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" Sources/Bridge/*.swift Tools/LiveSmoke.swift -o .build/tools/live-smoke
.build/tools/live-smoke "$@"
