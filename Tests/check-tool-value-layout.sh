#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-value-layout-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library Shared/AppLanguage.swift \
  "Paint Anytime (Watch) Watch App/ToolSettings/ToolValueControl.swift" \
  Tests/ToolValueLayoutChecks.swift -o "$check_dir/check"
"$check_dir/check"
