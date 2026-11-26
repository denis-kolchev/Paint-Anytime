#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-architecture-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/Document/CanvasDocument.swift Shared/Localization/AppLanguage.swift Shared/App/AppReleaseFeatures.swift \
  Shared/Drawing/BrushGeometry.swift Shared/Drawing/FountainPenGeometry.swift Shared/Drawing/PencilTool.swift Shared/Drawing/ShapeRecognizer.swift \
  Shared/Drawing/CanvasController.swift Shared/Tools/ToolSettings.swift Shared/Tools/ToolPreferencesStore.swift \
  Shared/Gallery/GalleryWidgetStore.swift Shared/Document/PaintProject.swift \
  "Paint Anytime (Watch) Watch App/Gallery/CanvasExport.swift" \
  "Paint Anytime (Watch) Watch App/Gallery/CanvasExportStore.swift" \
  Tests/ArchitectureChecks.swift -o "$check_dir/check"
"$check_dir/check"
