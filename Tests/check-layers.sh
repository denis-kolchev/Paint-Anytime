#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-layer-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/CanvasDocument.swift Shared/AppLanguage.swift Shared/AppReleaseFeatures.swift \
  Shared/BrushGeometry.swift Shared/FountainPenGeometry.swift Shared/PencilTool.swift Shared/ShapeRecognizer.swift \
  "Paint Anytime (Watch) Watch App/WatchStrokeDrawing.swift" \
  "Paint Anytime (Watch) Watch App/WatchDrawingCommands.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchBitmapRenderer.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchBitmapCache.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchLayerCompositor.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchSelectionRenderCache.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchFloodFill.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchFillWorker.swift" \
  "Paint Anytime (Watch) Watch App/Rendering/WatchArtworkRenderer.swift" \
  "Paint Anytime (Watch) Watch App/WatchStrokeCoverage.swift" \
  Tests/LayerRendererChecks.swift -o "$check_dir/check"
"$check_dir/check"
