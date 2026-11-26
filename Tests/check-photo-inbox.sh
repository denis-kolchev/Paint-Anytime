#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/paint-inbox-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
  Shared/Document/PaintProject.swift \
  "Paint Anytime iPhone/WatchLink/IncomingDrawingStore.swift" \
  "Paint Anytime iPhone/Photos/PhotoLibraryWriter.swift" \
  "Paint Anytime iPhone/WatchLink/WatchPhotoInbox.swift" \
  Tests/PhotoInboxChecks.swift -o "$check_dir/check"
"$check_dir/check"
