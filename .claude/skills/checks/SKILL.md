---
name: checks
description: How to prove a change to the Screendrop Mac app works, the way Pete would check it by hand. Build the Dev app, run the check harness, and walk its screens in a borrowed Mac VM, never on Pete's own desktop. Use before calling any change in this repo done, inside a ship run or not.
---

# Checks for Screendrop (Mac)

What every session that proves a change here starts from. A QA run reads it first and
writes back what it learned, in the same branch as the change. The web side (share pages,
library, MCP) has its own checks skill in screendrop-worker.

## Start it

- Build, sandbox off: `xcodebuild -project Screendrop.xcodeproj -scheme "Screendrop Dev"
  -configuration "Debug Dev" -derivedDataPath <job tmp>/dd build`.
- Harness: `sh scripts/check-loom-parity.sh "<dd>/Build/Products/Debug Dev/Screendrop Dev.app"`
  prints "loom parity checks passed" and "loom app checks passed".
- Never drive the app on Pete's Mac. Screens are walked in a borrowed VM through ship's
  `scripts/mac-vm.sh`, run from the worktree that holds the slot:
  `borrow --wait` (600000 ms timeout), `put 1 <app>`, `tunnel 1 3141` for the worker,
  `shot 1 <png>`, and `return 1` the moment the walk ends.
- Fake camera: copy a movie in with `run 1 'cat > /Users/lume/cam.mp4' < <movie>`.
- Launch over ssh so the app inherits the screen capture grant:
  `SCREENDROP_FAKE_CAMERA=/Users/lume/cam.mp4 nohup "/Users/lume/Applications/Screendrop
  Dev.app/Contents/MacOS/Screendrop Dev" > /tmp/sd.log 2>&1 < /dev/null & disown`.
- Defaults (`com.fayazahmed.Screendrop.dev`): `includeAppWindowsInCaptures -bool true`, or
  every app window is invisible in shots; `recordingCameraDeviceID fake`. The bubble's
  corner is JSON data under `recordingBubbleState`.

## Sign in

- Settings → Cloud: Worker URL `http://localhost:3141`, token `dev-token`. Re-enter the
  token after a relaunch; type it with `agent-desktop type --headed <ref> "dev-token"`.

## Walk

- **Clicks**: shots are 1920x1440 pixels at scale 2, so points are half.
  `agent-desktop mouse-click --headed --xy <x>,<y>`. Ready bar at y 588: close 234,
  Record about 717.
- **Hover**: only `mouse-move --headed`, moved from outside into the target, fires a
  tracking area. The camera bubble's controls need it.
- **Menus**: click to open, then `press --headed down` per item, wait half a second, then
  `press --headed return`. Mouse clicks on menu items don't land.
- **Accessibility tree**: `snapshot` and `list-windows` often time out while the recorder
  is up; work from shots and coordinates.
- **Hidden from captures by design**: the Claude Code chip, click dots, Point pin and its
  label field, the pen panel. Check them in the take's `claude-log.json` with `jq`, or
  through MCP. No `python3` in the VM: it opens the developer tools installer.
- **Discard a take**: click X, then a quick second click; a slow one re-arms "Delete?".
- **Debugging**: `NSLog("PROBE …")`, rebuild, `put`, relaunch, `grep PROBE /tmp/sd.log`.
  Remove it before committing.

## Pass lines

| Check | When | Passes when | On a fail |
|---|---|---|---|
| Build | every change | `BUILD SUCCEEDED` | the first `error:` line |
| Harness | every change | both "checks passed" lines | the named check |
| VM walk | anything a person sees | every step of the QA script, with a shot each | the shot, then a probe |

## Learned

- 2026-11-04 loom-parity: a hosting view with `sizingOptions = []` reports fittingSize 0
  by 0; measure a spare copy of the SwiftUI view instead. The bubble's controls sat under
  the Dock because of it.
- 2026-11-04 loom-parity: the VM can't check the mic level, transcripts (no mic), OCR
  (returns nothing), or Esc during the countdown (no key reaches the app after a Record
  click until the countdown ends). Those go to Pete on a real Mac.
- 2026-11-04 loom-parity: ScreenCaptureKit's shareable-content call can hang in the VM and
  leave Record disabled; close and reopen the recorder.
