#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-share-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  "Paint All the Time (Watch) Watch App/DrawingShareItem.swift" \
  Tests/DrawingShareChecks.swift -o "$check_dir/check"
"$check_dir/check"
