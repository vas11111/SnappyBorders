#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build_path="${1:-$root/.build}"
cd "$root"
swift build --scratch-path "$build_path"
bin_path="$(swift build --scratch-path "$build_path" --show-bin-path)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sources=()
for source in Sources/SnappyBorders/*.swift; do
    if [[ "$source" != "Sources/SnappyBorders/main.swift" ]]; then
        sources+=("$source")
    fi
done
swiftc -sdk "$sdk_path" -swift-version 5 -D SB_TESTING -module-cache-path "$build_path/test-module-cache" \
    -I "$root/Sources/CSkyLight/include" -F /System/Library/PrivateFrameworks \
    -framework SkyLight -framework QuartzCore -framework CoreGraphics \
    -framework ApplicationServices "${sources[@]}" Tests/Regression/main.swift \
    -o "$bin_path/sbregression"
"$bin_path/sbregression"
