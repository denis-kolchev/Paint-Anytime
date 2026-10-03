#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-tutorial-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/CanvasDocument.swift Shared/AppLanguage.swift Shared/AppReleaseFeatures.swift \
  Shared/ToolSettings.swift Shared/ToolPreferencesStore.swift \
  "Paint All the Time (Watch) Watch App/TutorialProgress.swift" \
  "Paint All the Time (Watch) Watch App/TutorialSession.swift" \
  "Paint All the Time (Watch) Watch App/TutorialLesson.swift" \
  "Paint All the Time (Watch) Watch App/TutorialDebug.swift" \
  "Paint All the Time (Watch) Watch App/TutorialWorkspace.swift" \
  "Paint All the Time (Watch) Watch App/OnboardingController.swift" \
  "Paint All the Time (Watch) Watch App/TutorialCrownPlacement.swift" \
  Tests/TutorialChecks.swift -o "$check_dir/check"
"$check_dir/check"
