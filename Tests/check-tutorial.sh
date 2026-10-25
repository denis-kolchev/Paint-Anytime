#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-tutorial-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/CanvasDocument.swift Shared/AppLanguage.swift Shared/AppReleaseFeatures.swift \
  Shared/ToolSettings.swift Shared/ToolPreferencesStore.swift \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialProgress.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialSession.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialLesson.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialDebug.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialWorkspace.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/OnboardingController.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialCrownPlacement.swift" \
  Tests/TutorialChecks.swift -o "$check_dir/check"
"$check_dir/check"
