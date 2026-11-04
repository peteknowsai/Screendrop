#!/bin/sh
# Compiles the pure helpers the Loom parity work added with
# scripts/check-loom-parity.swift and runs the checks. Each task adds its
# helper files to the swiftc line.
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
  scripts/check-loom-parity.swift \
  -o "$work/check"
"$work/check"
