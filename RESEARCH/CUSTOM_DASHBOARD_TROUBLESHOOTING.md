# Custom Dashboard Firmware Troubleshooting

## Purpose

This document explains why the Even G1 stock dashboard and Even AI prompt
appeared before the app's custom dashboard, how the behavior was isolated on
real hardware, and why the final fix works.

The findings apply to the dual-arm G1 firmware tested in August 2026. Protocol
behavior may differ on other firmware revisions.

## Final outcome

With the custom dashboard enabled:

- Looking up emits the normal firmware head-up event and shows only the custom
  dashboard.
- The stock dashboard and Even AI prompt do not appear.
- Looking forward or down clears the custom dashboard.
- Disabling the custom dashboard restores the firmware's normal head-up action.
- Pairing and reconnecting do not require the official Even Realities app.

## Root cause

Head-up motion detection and the UI action assigned to that motion are separate
firmware controls.

The glasses can continue reporting a raw head-up event while their built-in
head-up action is mapped to `None`. The app originally changed the broader
head-up mode with commands `0x0A` and `0x0B`. On the tested firmware those
commands were slow, could trigger the Even AI surface, and could suppress the
head-up event entirely when configured as off.

The correct control is command `0x08`, which changes only the action associated
with head-up:

```text
08 06 00 00 03 02  -> map head-up action to None
08 06 00 00 03 00  -> restore the firmware's default head-up action
```

After sending the `... 02` mapping to both arms, the glasses continued emitting
`F5 02` head-up events, but stopped drawing the stock dashboard and Even AI
overlay. This separation is the key finding.

## Relevant protocol behavior

### Head events

The primary motion events observed in the successful sessions were:

- `F5 02`: head up
- `F5 03`: head down or return to level

These codes were initially treated as swipe events. Runtime traces showed that
they track deliberate head movement and must be routed as head events.

Other firmware event codes such as `F5 1E` and `F5 1F` were also observed around
dashboard state changes. They should not be used as the sole source of physical
motion truth without validating the firmware version.

### Firmware action mapping

Command `0x08` changes what the firmware displays after a head-up motion. It
does not disable motion reporting. The app sends the mapping after both arms
reach `fullyConnected`, and again when dashboard enablement changes:

- Custom dashboard enabled: suppress the firmware action with value `0x02`.
- Custom dashboard disabled: restore the default action with value `0x00`.

### Commands that must remain disabled

The app globally suppresses outbound head-up mode commands `0x0A` and `0x0B`.
On the tested firmware:

- `0x0A` commonly timed out.
- Falling back to `0x0B` added several seconds to startup.
- Sending these commands correlated with the Even AI prompt appearing.
- Configuring the mode as off could also stop head-up events, leaving the app
  unable to detect the gesture.

Command `0x08` is not interchangeable with `0x0A` or `0x0B`: it changes the
assigned action while preserving the event.

### Display ownership

The firmware dashboard and the app bitmap contend for the same lens surface.
Sending dashboard visibility command `0x07 01` re-enables the firmware-owned
surface and can allow stock UI to win.

The reliable custom-dashboard sequence is:

1. Receive and debounce `F5 02`.
2. Confirm that navigation or another higher-priority feature does not own the
   lens.
3. Send `0x18` to both arms and wait for both acknowledgements. This exits any
   residual firmware surface.
4. Render a fresh dashboard snapshot.
5. Upload the bitmap without sending `0x07 01`.
6. Finalize the upload with `0x20`, then verify it with `0x16`.

The upload is serialized through the display command gate so a clear, text
write, or another bitmap cannot race it.

### Head-down handling

The firmware can emit a fast head-down follow-up shortly after head-up. Acting
on it immediately clears a dashboard that is still being uploaded.

The dashboard therefore:

- Coalesces duplicate head-up and head-down events within one second.
- Ignores head-down events received less than 3.5 seconds after the accepted
  head-up.
- Sends `0x18` for a later, intentional head-down or return-to-level event.

This dwell is why the dashboard can finish rendering while still clearing
normally when the wearer looks forward or down.

## Troubleshooting chronology

### 1. Prove which UI owned each message

The stock dashboard, “your route is being generated,” and Even AI recording
prompt were not found in the app's rendered bitmap or text payloads. They could
appear before a custom bitmap completed, proving they were firmware-owned
layers rather than SwiftUI content.

### 2. Isolate persistent device state

The glasses were power-cycled and tested with only this app running. This ruled
out the official app as a required runtime participant and showed that some
head-up behavior is stored or executed by firmware.

### 3. Instrument the complete BLE path

Runtime logging recorded:

- Raw `0xF5` event codes and arm.
- Gesture routing and current lens owner.
- Every relevant outbound control command.
- Clear completion.
- Bitmap chunk, end, and CRC acknowledgement timing.
- Latched bitmap ownership and invalidation.

This was necessary because UI appearance alone could not distinguish firmware
rendering from an app upload race.

### 4. Reject `0x0A` and `0x0B` as the solution

Disabling head-up through the mode commands removed the event the app needed.
Other mode values remained slow and could provoke Even AI. A global kill switch
was added so no caller can accidentally send those commands.

### 5. Correct the event mapping

Raw `F5 02` and `F5 03` traffic consistently accompanied deliberate head-up and
head-down motion. Treating them as swipes caused the dashboard controller to
miss or misroute the real gesture. They were remapped to `headUp` and
`headDown`.

### 6. Remove the firmware dashboard visibility race

Uploading a bitmap after `0x07 01` allowed the stock dashboard layer to appear
or cover the custom frame. The head-up path was changed to clear with `0x18`
and upload directly without re-enabling `0x07`.

This removed the stock dashboard, but an intermittent Even AI flash remained.

### 7. Filter immediate firmware follow-up events

The logs showed head-down events arriving while the bitmap transfer was still
in progress. A 3.5-second dwell prevented these events from clearing an
incomplete frame while preserving later intentional clears.

### 8. Correlate, then reject, `F5 12` as the direct cause

An initial session with an Even AI flash also contained `F5 12`, while a clean
attempt did not. Additional instrumentation tracked this code as a possible
long-press or AI action event.

After applying the `0x08` action mapping, `F5 12` still appeared once without
any Even AI UI. Therefore `F5 12` may report related firmware activity, but it
is not sufficient to trigger the overlay. No behavior is attached to it.

### 9. Test the separate `0x08` action mapping

The app sent `08 06 00 00 03 02` to both arms. Both acknowledged it, raw
`F5 02` events continued, and repeated head-up cycles showed only the custom
dashboard. This confirmed that the firmware action—not motion detection—was
the remaining source of stock UI.

### 10. Promote the experiment into the lifecycle

The manual test controls were removed. `DashboardViewModel` now applies the
suppression automatically after a full connection and whenever the dashboard
setting changes. A generation check prevents a stale asynchronous
configuration result from overriding a newer setting.

## Verification evidence

The final automatic verification run established all required properties:

- Both arms acknowledged `08 06 00 00 03 02`.
- The first `F5 02` arrived after suppression was acknowledged.
- Three consecutive head-up cycles uploaded complete 576×135 frames.
- The uploads completed in approximately 0.93–0.95 seconds.
- `0x20` and `0x16` were acknowledged by both arms without retry.
- Each later `F5 03` caused an acknowledged `0x18` clear.
- The wearer observed no stock dashboard or Even AI message.

The temporary diagnostic instrumentation was removed after this successful
post-fix run.

## Pairing and reconnection findings

Pairing issues were separate from display ownership but complicated testing:

- Cached Core Bluetooth UUIDs could reconnect the app to stale peripherals.
  “Scan for a new pair” clears only the app's remembered identifiers and starts
  broad discovery; it does not factory-reset the glasses.
- New pairing normally starts with `4D 01`.
- If unbonded initialization times out, `F4 01` is used as a bonding bootstrap,
  followed by another `4D 01` attempt.
- iOS can present pairing prompts during this process.
- After both prompts are accepted, the app retries initialization and reconnects
  automatically.

The official Even Realities app is not required for pairing. It can change
firmware settings, however, so hardware behavior should be validated with only
one companion app active.

## Approaches that did not solve the problem

- Repeatedly sending `0x0A` or `0x0B`.
- Setting head-up mode to off.
- Mapping the mode to Notes.
- Showing the dashboard with `0x07 01` before bitmap upload.
- Assuming stock strings were generated by app code.
- Treating every immediate head-down as intentional.
- Treating `F5 12` as the direct Even AI trigger.
- Factory-resetting or depending on the official app for every pairing attempt.
- Relying only on pre-latching while later clears invalidated the stored frame.

## Code locations

- `Sources/EvenG1Core/Constants.swift`
  - Compatibility command `headUpAction = 0x08`
  - Primary head events `0x02` and `0x03`
- `Sources/EvenG1Core/FrameParser.swift`
  - Raw device-event mapping
- `Sources/EvenG1Core/G1BluetoothManager.swift`
  - Global `0x0A`/`0x0B` suppression
  - `setFirmwareHeadUpActionSuppressed(_:)`
  - Serialized clear and bitmap transport
  - Pairing fallback and remembered-device reset
- `EvenG1-Swift/Dashboard/DashboardViewModel.swift`
  - Connection/settings synchronization
  - Lens ownership checks
  - Gesture debounce and dwell
  - Clear, render, and upload lifecycle
- `EvenG1-Swift/ContentView.swift`
  - Gesture routing through `G1LensSurfaceArbiter`

## Diagnostic checklist

If stock UI returns on another firmware version:

1. Confirm both arms acknowledge the `0x08 ... 0x02` mapping before the first
   head-up.
2. Confirm no caller emits `0x0A` or `0x0B`.
3. Confirm the physical gesture still emits `F5 02`.
4. Confirm head-up sends `0x18` before the first `0x15` bitmap chunk.
5. Confirm the upload path does not send `0x07 01`.
6. Confirm `0x20` and `0x16` complete on both arms.
7. Confirm a real `F5 03` after the dwell sends `0x18`.
8. Record unknown `0xF5` codes rather than assigning behavior from a single
   correlation.

The recurring Datadog feature-flag error, PointerUI warning, and
“cannot add handler” messages appeared in both failing and successful sessions.
They were not causal to the BLE or display behavior.
