## Session Summary

Debugging session on the EvenG1-Swift iOS app, which drives Even Realities G1
smart glasses over BLE. The work centred on the navigation feature: rendering a
monochrome street map into a 576×135 one-bit bitmap, uploading it to the glasses,
and reacting to head-tilt and touch gestures. The session used a strict
runtime-evidence loop: form hypotheses, instrument with NDJSON logs, have the
user reproduce on real hardware, then confirm or reject from the logs.

Current state: startup latency, the phantom Even AI prompt, the user-marker
geometry, the Apple Maps logo, and the phantom swipe storm are all fixed and
confirmed by logs. One bug remains open and is the next agent's whole job: the
app receives almost no Core Location updates while navigating, so the map on the
glasses does not follow the wearer. Instrumentation to identify the cause is
already in place and installed on the device; the run has not been performed yet.

## Load on Startup

Before taking any action, the new agent must read these files in order:

1. `RESEARCH/GLASSES_FIRMWARE_BEHAVIOR.md` — every confirmed firmware behaviour
   and protocol finding from this session, with the runtime evidence behind each.
   Reading this prevents re-deriving decoded event codes or repeating the two
   changes that made things worse.
2. `RESEARCH/NAVIGATION_BITMAP_RENDERING.md` — the display-ownership rules, map
   window geometry, and head-gesture design that the navigation code follows.
3. `EvenG1-Swift/Navigate/RouteTracker.swift` — holds the open bug's
   instrumentation; this is where the next evidence will come from.
4. `EvenG1-Swift/Navigate/NavigationViewModel.swift` — the navigation state
   machine, upload throttles, and gesture handling; the largest surface of
   changes this session.

## Environment

- Working directory: `/Users/ronny.coste/Documents/Github/EvenG1-Swift`
- Physical device required. iPhone device ID:
  `8C2DE854-26A8-5E9D-AAB4-435EF6D8DC3B`, bundle ID `com.kosukobo.EvenG1-Swift`.
  The simulator cannot exercise BLE or the glasses.
- Build: `xcodebuild -scheme EvenG1-Swift -destination 'id=<device-id>' -allowProvisioningUpdates build`
- Install: `xcrun devicectl device install app --device <device-id> ~/Library/Developer/Xcode/DerivedData/EvenG1-Swift-cltmfprfdbrspxghflkyhzzfizuj/Build/Products/Debug-iphoneos/EvenG1-Swift.app`
- Tests: run through Xcode, not SwiftPM. `swift test` fails with a pre-existing
  macOS platform mismatch between `EvenG1Core` (10.13) and the Datadog products
  (12.6). Use
  `xcodebuild test -scheme EvenG1-Swift -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<target/class>`.
- Debug log path on the Mac after copying: any local path. On the device the app
  appends NDJSON to `Documents/debug-bf2a66.log` inside the app container.
- Pull the log:
  `xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer --domain-identifier com.kosukobo.EvenG1-Swift --source Documents/debug-bf2a66.log --destination /tmp/run.log`
- Clear the log before every run by pushing an empty file:
  `xcrun devicectl device copy to --device <device-id> --domain-type appDataContainer --domain-identifier com.kosukobo.EvenG1-Swift --source /tmp/empty-debug.log --destination Documents/debug-bf2a66.log`
- Key project files: `Sources/EvenG1Core/Constants.swift` (protocol bytes),
  `Sources/EvenG1Core/FrameParser.swift` (frame → event decoding),
  `Sources/EvenG1Core/G1BluetoothManager.swift` (BLE transport and commands).

## Decisions & Outcomes

- **Never send head-up mode commands (`0x0A`/`0x0B`) to this firmware.** An
  attempt to claim the display surface by disabling the firmware's head-up
  feature cost 6.4 s of BLE timeouts on the critical path (the primary byte
  never ACKs, only the fallback does), silenced the `headUp` event entirely, and
  triggered the stock "release to finish recording Even AI" overlay at startup.
  All of it was reverted. This was the single worst change of the session.
- **Head-up must stay firmware-owned, with a dwell timer absorbing the follow-up
  head-down.** The firmware genuinely emits a head-down 500–700 ms after every
  head-up. `overviewHoldSeconds = 8` in `NavigationViewModel` ignores head-downs
  inside that window and auto-returns afterwards. Confirmed working in logs.
- **The head tilt is the discrete `F5 1E`/`F5 1F` event, not an angle threshold.**
  An earlier theory that `F5 0A <byte>` carried pitch degrees was disproved by a
  labelled tilt run. Do not build tilt logic on `0x0A`.
- **Navigation ignores swipe events.** The right temple reports swipes nobody
  made, as perfectly alternating forward/backward pairs. Step previews stay on
  the phone. Implemented in `G1NavigationGestureMapper`.
- **`G1FrameParser.parseStatusResponse` was suspected and cleared.** Frame-level
  logging proved the phantom gestures are real `0xF5` frames. Its loose
  heuristics were left untouched deliberately; see Deferred.
- **Text and bitmap share one display surface.** Any text packet (`0x4E`) during
  navigation wipes the map, so all navigation output must render into the bitmap.
- **User preference: minimise BLE traffic.** This motivated the zoom level (a
  roughly five-block head-level window) and constrains how aggressively the
  refresh cadence can be raised.

## Files & Artifacts

| File | Description | Status |
|------|-------------|--------|
| `RESEARCH/GLASSES_FIRMWARE_BEHAVIOR.md` | New. Firmware event-code table, measured command costs, spurious-gesture analysis, frame-freshness findings, MapKit quirks. Marks each item proven or inferred. | complete, untracked in git |
| `RESEARCH/NAVIGATION_BITMAP_RENDERING.md` | Updated map-window/user-marker section and rewrote head-gesture guidance. | complete |
| `EvenG1-Swift/Navigate/RouteTracker.swift` | Core Location tracking. Carries the open bug's instrumentation: raw callback logging, pause/resume/failure delegates. No fix applied yet. | instrumented, awaiting evidence |
| `EvenG1-Swift/Navigate/NavigationViewModel.swift` | Navigation state machine. Reverted the firmware claim; added dwell timer, start-latency measurement, refresh-skip logging, location enqueue logging; `minimalBitmapInterval` 15 s → 8 s. | complete for confirmed fixes |
| `EvenG1-Swift/Navigate/NavigationBitmapRenderer.swift` | Bitmap rendering. Look-ahead clipping by interpolation, user-anchor clamp, Apple logo crop, `uploadSignature` position quantum 200 m → 12 m. | complete |
| `Sources/EvenG1Core/G1NavigationGestureMapping.swift` | Swipes now map to nil during navigation. | complete |
| `Sources/EvenG1Core/G1BluetoothManager.swift` | Frame-level instrumentation only (gesture source frames, unmapped control frames). No behavioural change. | instrumented |
| `Tests/EvenG1CoreTests/G1NavigationGestureMappingTests.swift` | Updated for the swipe change. Passing. | complete |
| `outputs/session-handoffs/session-handoff-2026-08-20.md` | This document. | complete |

Note: `RESEARCH/GLASSES_FIRMWARE_BEHAVIOR.md` is untracked. Add it before any
commit; it is the most valuable artifact of the session.

## Unsaved Code & Outputs

### Log analysis commands

Included because the next agent will need to re-run this analysis on a fresh log
and these exact queries are what produced the session's conclusions.

```bash
# Per-hypothesis view of the open bug
jq -r 'select(.data.hypothesisId=="H32" or .hypothesisId=="H32") | "\(.timestamp) \(.message) \(.data|tostring)"' /tmp/run.log

# Upload cadence and start latency
jq -r 'select(.message=="bitmap upload result") | "\(.timestamp) \(.data.detail) ms=\(.data.msSinceNavigationStart)"' /tmp/run.log

# Did the map window actually move?
jq -r 'select(.message=="map window") | "\(.timestamp) \(.data.detail) EW=\(.data.spanEastWestMeters) userY=\(.data.snapshotUserY)"' /tmp/run.log

# Event mix, to spot phantom gestures
jq -r 'select(.message=="glasses event") | .data.event' /tmp/run.log | sed 's/, payload.*//' | sort | uniq -c | sort -rn
```

### Baseline measurements to compare against

Included because the next agent must know what "better" looks like without
re-deriving it.

```text
Start latency:        1703 ms and 1844 ms to first frame (was 7900 ms)
Location updates:     3 in a 3.5-minute walk (expected tens at a 5 m filter)
Phantom swipes:       19 perfectly alternating F/B pairs per session, right arm
Head event shape:     F5 1E up, F5 1F down, one per arm, pair within ~200 ms
Firmware head-down:   500-700 ms after every head-up
Minimal map window:   699 m x 205 m, user marker at y=21 px (matches expected)
Detailed map window:  2180 m x 643 m, user marker at y=24 px
```

## Remaining TODOs

**In progress:**

- The open bug: almost no Core Location updates reach `NavigationViewModel`
  during navigation, so the glasses map does not follow the wearer. Three
  candidate causes remain: automatic pausing
  (`pausesLocationUpdatesAutomatically` defaults to true and was never
  disabled — the leading suspect for a turn-by-turn app), an authorization or
  accuracy problem, or main-actor starvation from the previous bitmap upload
  storm. Instrumentation is installed on the device and the log is cleared; only
  the walking reproduction is missing.
- Verification that the swipe fix stopped the display churn, and that the head-up
  overview looks correct once the position is live. Both ride along with the same
  run.

**Queued:**

- Remove all debug instrumentation once the location fix is confirmed. It is
  intentionally still present. Every site is wrapped in `// #region agent log` /
  `// #endregion`. Inventory: `NavigationViewModel.swift` (22 regions),
  `RouteTracker.swift` (5), `G1BluetoothManager.swift` (2, including a private
  `agentLog` helper that must go so the core package stops writing to the app's
  Documents directory), `NavigationBitmapRenderer.swift` (2).
- Re-evaluate `minimalBitmapInterval = 8` once location updates flow. It was
  chosen against a frozen-position baseline; the right cadence should be
  reconsidered against the user's stated wish to keep BLE traffic low.

**Deferred:**

- Tightening `G1FrameParser.parseStatusResponse`. It scans a `0x22` payload for a
  stray `0xF5` byte anywhere and otherwise treats `payload[0]` as an event code,
  so status data can fabricate gestures. It was cleared as the cause of the
  observed phantom swipes, so it was left alone rather than changed without
  evidence. Worth hardening as a separate, tested change.
- Remapping the side-button press-and-hold, which currently ends navigation and
  collides with the stock Even AI start gesture.
- Decoding the remaining `0xF5` status codes: `0x06`, `0x07`, `0x08`, `0x09`,
  `0x0A`, `0x0E`, `0x12`. Observed as lifecycle and periodic status; only rough
  inferences are recorded in the research doc.
- Restoring step previews on the glasses through a gesture the firmware reports
  reliably, since swipes are now ignored.

## How to Resume

Your first action is to ask the user to perform the walking reproduction that is
already staged: the current build is installed on the device and
`Documents/debug-bf2a66.log` is empty. The user must start a route, walk at least
two blocks (about three minutes) with the app in the foreground and the phone in
hand, then hold their head level for 15 s, tilt up and hold for 15 s, and stop
navigation.

Then pull the log and evaluate exactly one hypothesis set, tagged `H32`: count
`core location callback` entries and check for `core location paused updates`. If
the pause entry appears, or if callbacks are absent while
`route tracker start` reports `pausesAutomatically: true`, the fix is to set
`pausesLocationUpdatesAutomatically = false` in `RouteTracker.init()` (and
consider `allowsBackgroundLocationUpdates` with the matching background mode if
the user wants the screen off). If callbacks arrive but `location enqueued` shows
`coalescedAway: true` repeatedly, the bug is in the view model's coalescing
instead. Do not change location configuration before reading those log lines.
