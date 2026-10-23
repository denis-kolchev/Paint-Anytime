#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-shape-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/CanvasDocument.swift Shared/AppLanguage.swift Shared/AppReleaseFeatures.swift \
  Shared/ShapeRecognizer.swift Shared/PencilTool.swift \
  Tests/ShapeRecognitionChecks.swift -o "$check_dir/check"
"$check_dir/check"
