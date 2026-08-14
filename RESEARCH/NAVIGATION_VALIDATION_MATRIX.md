# Navigation Hardware Validation Matrix

## Scenarios

1. Walking route
- Start walking route from search destination.
- Verify first instruction appears on phone and glasses.
- Verify maneuver step changes update automatically.

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

7. Native-to-fallback transition
- Force repeated native ACK failures.
- Verify transport switches to text fallback.
- Export trace JSONL and confirm mode switch entries are present.

## Evidence Collection

- Open Navigate, tap the waveform diagnostics button, and confirm the session,
  connection, transport mode, trace count, and recent records match the run.
- Tap **Export chronological JSONL** after each scenario. The exported file is
  ordered oldest-to-newest, uses ISO 8601 timestamps, and is newline-terminated
  for direct use with JSONL tooling.
- Save app debug logs with timestamps.
- Name or annotate each exported file with its scenario number.
- Record side (left/right) and firmware version for each test run.
