# Navigation Hardware Validation Matrix

## Scenarios

1. Walking route
- Start walking route from search destination.
- Verify an initial route bitmap appears promptly without waiting for MapKit
  tiles, then is replaced by a street-map bitmap.
- Verify roads, street names, route, user marker, instruction, and ETA remain
  visible after one-bit conversion.
- Verify maneuver step changes update automatically.
- Verify no text packet replaces the bitmap during the trip.

2. Transit route
- Start transit route.
- Verify step instructions and ETA update on glasses.
- Verify route summary remains readable in fallback text mode.

3. Biking route
- Start biking route.
- Verify MapKit returns a cycling route and renders its polyline in-app.
- Verify cycling maneuvers, rerouting, ETA, and progress reach the glasses.
- Verify route summary remains readable in fallback text mode.

4. Off-route auto-reroute
- Deviate from route by >70m.
- Verify reroute triggers automatically.
- Verify navigation session remains active without manual prompt.

5. Mid-route connection loss
- Disconnect one or both glasses while navigating.
- Verify session state resets and no crash.
- Reconnect and verify guidance can resume.

6. Gesture stress
- Rapidly trigger double tap/swipe/press events.
- Verify debounce prevents duplicate actions.
- Verify controls only execute while navigation session is active.
- Verify head-up shows the detailed map and head-down restores the minimal map.
- Verify the stock dashboard and transit widget never replace or clear the
  navigation bitmap.

7. Native-to-fallback transition
- Force repeated native ACK failures.
- Verify bitmap navigation does not wait for native ACK retries or switch to
  text during an active route.
- Export trace JSONL and confirm mode switch entries are present.

8. Slow/offline network
- Start navigation with constrained or unavailable networking.
- Verify the immediate vector route remains usable.
- Verify lens rendering performs no MapKit snapshot request.

9. Binocular alignment A/B
- Record the current eye-distance and height settings from Device → Glasses
  Configuration before changing anything.
- Send a working MTA transit bitmap and confirm both lenses show one fused image.
- Send a centered calibration frame (vertical line at canvas center) and confirm
  both lenses align on the same relative position.
- Start navigation with the same display-position settings and confirm the route
  line appears once across both lenses, not as a horizontally offset ghost.
- Capture the in-app HUD preview and a glasses photo for the same frame.
- Verify logs show one ordered bitmap transaction per visual change with no
  dashboard (`0x0A`/`0x07`) or heartbeat (`0x25`) commands between the first
  `0x15` chunk and the final `0x16` CRC ACK.

10. Street wireframe and head-up overview
- Start navigation in a built-up area and confirm the glasses show white street
  lines with a thicker route line, with no building footprints or block fills.
- Confirm the head-level frame covers the next stretch of the walk and keeps the
  turn instruction on the top line.
- Tilt the head up and confirm the frame switches within about two seconds to the
  whole remaining route on a wider surface, with the instruction line dropped.
- Tilt back down and confirm the head-level frame returns.
- Repeat over water or open country and confirm a low-contrast tile leaves the
  route and stats visible instead of flooding the display.

## Evidence Collection

- Open Navigate, tap the waveform diagnostics button, and confirm the session,
  connection, transport mode, trace count, and recent records match the run.
- Tap **Export chronological JSONL** after each scenario. The exported file is
  ordered oldest-to-newest, uses ISO 8601 timestamps, and is newline-terminated
  for direct use with JSONL tooling.
- Save app debug logs with timestamps.
- Name or annotate each exported file with its scenario number.
- Record side (left/right) and firmware version for each test run.
- For `IDEDebugSessionErrorDomain Code 24`, check device crash/diagnostic logs
  before classifying the event as an app crash. See
  `RESEARCH/NAVIGATION_BITMAP_RENDERING.md`.
