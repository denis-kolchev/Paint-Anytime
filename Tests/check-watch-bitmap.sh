#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-bitmap-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/CanvasDocument.swift Shared/AppLanguage.swift Shared/AppReleaseFeatures.swift \
  Shared/BrushGeometry.swift Shared/FountainPenGeometry.swift \
  "Paint All the Time (Watch) Watch App/WatchStrokeDrawing.swift" \
  "Paint All the Time (Watch) Watch App/WatchDrawingCommands.swift" \
  Tests/WatchBitmapRendererChecks.swift -o "$check_dir/check"
"$check_dir/check"
