#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-deep-link-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library Shared/PaintDeepLink.swift \
  "Paint Anytime (Watch) Watch App/App/WatchLaunchRequest.swift" \
  Tests/DeepLinkChecks.swift -o "$check_dir/check"
"$check_dir/check"
