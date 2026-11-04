#!/bin/sh
# Compiles the pure helpers the Loom parity work added with
# scripts/check-loom-parity.swift and runs the checks. Each task adds its
# helper files to the swiftc line.
#
# Given a built Debug app (scripts/check-loom-parity.sh path/to/App.app),
# it also runs the checks that need the whole app module (LoomAppChecks),
# which print and exit before any UI starts.
set -eu
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/screendrop-loom-parity-check"
mkdir -p "$work"
xcrun swiftc -module-cache-path "$work/ModuleCache" \
  Screendrop/RecordingRenderKey.swift \
  Screendrop/CaptureHotkeys.swift \
  Screendrop/RecordingPrivacyChoice.swift \
  Screendrop/RecordingScreenCleanup.swift \
  Screendrop/InlineConfirm.swift \
  Screendrop/CameraBubbleModel.swift \
  Screendrop/CameraFilter.swift \
  scripts/check-loom-parity.swift \
  -o "$work/check"
"$work/check"

if [ $# -gt 0 ]; then
  app="$1"
  "$app/Contents/MacOS/$(basename "$app" .app)" --loom-checks
fi
