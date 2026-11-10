#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-shape-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/Document/CanvasDocument.swift Shared/Localization/AppLanguage.swift Shared/App/AppReleaseFeatures.swift \
  Shared/Drawing/ShapeRecognizer.swift Shared/Drawing/PencilTool.swift \
  Tests/ShapeRecognitionChecks.swift -o "$check_dir/check"
"$check_dir/check"
