#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-inbox-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  "Paint Anytime iPhone/IncomingDrawingStore.swift" \
  "Paint Anytime iPhone/PhotoLibraryWriter.swift" \
  "Paint Anytime iPhone/WatchPhotoInbox.swift" \
  Tests/PhotoInboxChecks.swift -o "$check_dir/check"
"$check_dir/check"
