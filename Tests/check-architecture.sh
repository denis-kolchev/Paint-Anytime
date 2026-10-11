#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-architecture-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/CanvasDocument.swift Shared/AppLanguage.swift Shared/AppReleaseFeatures.swift \
  Shared/BrushGeometry.swift Shared/FountainPenGeometry.swift Shared/PencilTool.swift Shared/ShapeRecognizer.swift \
  Shared/CanvasController.swift Shared/ToolSettings.swift Shared/ToolPreferencesStore.swift \
  "Paint Anytime (Watch) Watch App/CanvasExport.swift" \
  "Paint Anytime (Watch) Watch App/CanvasExportStore.swift" \
  Tests/ArchitectureChecks.swift -o "$check_dir/check"
"$check_dir/check"
