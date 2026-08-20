# Navigation Bitmap Rendering

## Display ownership

The G1 exposes one display surface. Text packets and bitmap uploads replace each
other; they cannot be layered. During an active route, the navigation bitmap is
therefore the only display output. It contains:

- a local Apple Maps snapshot with roads and street labels;
- the upcoming route drawn with a black halo and white center line;
- a route-snapped user marker (GPS errors up to 75 m);
- the next instruction, turn distance, and remaining time.

The current firmware NACKs the experimental native navigation command family.
Navigation must not wait for those retries or downgrade to text, because that
text would replace the map.

## Startup sequence

1. Mark the local glasses navigation session active without sending unsupported
   native navigation packets.
2. Reuse the location obtained while building the route; do not request another
   one-shot location.
3. Render and upload a local vector route immediately.
4. Configure app-driven head-up/down events asynchronously.
5. Generate the network-backed `MKMapSnapshotter` image and replace the initial
   frame when it is ready.

This keeps the Start action independent of BLE ACK timeouts and MapKit tile
latency. Snapshot generation and tilt setup are generation-guarded so a frame
from a stopped route cannot be uploaded later.

## Monochrome conversion

MapKit dark-mode roads are much dimmer than labels. A threshold of 96 produced
the observed "text-only map": labels survived while streets were discarded.
Navigation uses a threshold of 42 and excludes POI icons/labels, retaining road
geometry and street names without overwhelming the 576×135 one-bit display.

The snapshot is cached by a quantized map rectangle. The route and instruction
overlay can update without downloading/rendering identical map tiles.

## Map window and the user marker

The window is built from a look-ahead budget along the route, clipped by
interpolating a final vertex exactly at the budget rather than appending whole
route segments; appending segments overshot far enough to push the user marker
off the canvas (measured at y = -86 px). The map rect is then centered so the
user stays inside an 18% margin.

Confirmed on device: minimal detail renders a 699 m × 205 m window with the
marker at y = 21 px, matching the expected y exactly.

## Head gestures

- Head up: detailed map, approximately 2 km of route context.
- Head down: minimal map, approximately 700 m of route context.

Head-up remains a firmware-owned gesture. The app must not disable firmware
head-up mode to claim the display: doing so also suppresses the `headUp` event,
and configuring it costs about 6 s of BLE timeouts. Instead the app absorbs the
firmware's fast follow-up `headDown` with a dwell timer so the overview stays
up. See `GLASSES_FIRMWARE_BEHAVIOR.md` for the supporting measurements.

Transit gesture handlers yield while navigation owns the display.

## Debugger disconnects

`IDEDebugSessionErrorDomain Code 24` means LLDB lost its connection to the
phone; it is not, by itself, an application crash report. This is especially
plausible when the device OS is newer than the installed Xcode SDK (for example,
iOS 27.0 with an iOS 26.5 SDK).

To distinguish a debugger/device-support disconnect from an app crash:

1. Relaunch the installed app without Xcode. If it remains installed and opens,
   the prior error was likely the debug transport.
2. Check Xcode's Devices and Simulators device logs for an
   `EvenG1-Swift` `.ips` crash or jetsam report at the same timestamp.
3. Capture the app console and glasses diagnostics around route start.
4. Collect a paired Mac/device sysdiagnose only when reporting the LLDB
   disconnect to Apple.

## Hardware validation

- Start should show the initial route frame promptly, before map tiles finish.
- The detailed snapshot should replace it without any intervening text frame.
- Verify streets remain visible in one-bit output in bright and dim conditions.
- Confirm logs contain `Head Up`/`Head Down`, and each gesture produces a
  `navigation_map_upload` with the expected detail level.
- Stop navigation before starting another route and confirm no stale frame is
  uploaded afterward.
