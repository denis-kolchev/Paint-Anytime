#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-tutorial-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/Document/CanvasDocument.swift Shared/Localization/AppLanguage.swift Shared/App/AppReleaseFeatures.swift \
  Shared/Tools/ToolSettings.swift Shared/Tools/ToolPreferencesStore.swift \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialChapter.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialProgress.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialSession.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialLesson.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialDebug.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialWorkspace.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/OnboardingController.swift" \
  "Paint Anytime (Watch) Watch App/Tutorial/TutorialCrownPlacement.swift" \
  Tests/TutorialChecks.swift -o "$check_dir/check"
"$check_dir/check"
