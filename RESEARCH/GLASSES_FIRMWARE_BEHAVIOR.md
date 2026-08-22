# G1 Firmware Behavior Notes

Observed on real hardware (dual-arm G1, firmware as shipped mid-2026) while
debugging navigation, display ownership, and Live Captions gesture control.
Every entry below is backed by runtime logs from device sessions; the
"confidence" column separates what the logs prove from what remains inference.

For the complete custom-dashboard investigation and final implementation, see
[`CUSTOM_DASHBOARD_TROUBLESHOOTING.md`](CUSTOM_DASHBOARD_TROUBLESHOOTING.md).
For the TouchBar/Live Captions investigation, see
[`LIVE_CAPTIONS_GESTURE_CONTROL.md`](LIVE_CAPTIONS_GESTURE_CONTROL.md).

## 0xF5 device event codes

The firmware sends notifications as `0xF5 <code> <value> <18 zero bytes>`. Codes
the app maps (tap/swipe/head) are in `G1DeviceEvent`. Codes observed as
`unknown` during navigation sessions:

| Code | Observed values | Meaning | Confidence |
| --- | --- | --- | --- |
| `0x00` | `00` | double-tap close/exit while an advanced text surface is active | verified |
| `0x02` | `00` | primary head-up motion event on tested firmware | verified |
| `0x03` | `00` | primary head-down/return-to-level motion event on tested firmware | verified |
| `0x07` | `00` | display/dashboard surface state, reported single-arm | inferred |
| `0x08` | `00` | wear or case state change, always a left+right pair | inferred |
| `0x09` | `01` | wear or case state change, always a left+right pair | inferred |
| `0x0A` | `18`-`21`, `28`, `32`-`39` | part of a recurring `0A`/`09`/`0E` status triplet spaced about a second apart; not tilt, values do not track head movement | inferred |
| `0x0E` | `01` | charge or case state, immediately precedes `caseBattery` | inferred |
| `0x12` | `14` | long-press action follow-on; correlated with the stock flow but not sufficient to cause its UI | verified correlation |
| `0x17` | `00` | left TouchBar hold threshold / stock Even AI entry path | verified |
| `0x18` | `00` | left TouchBar release after `F5 17` | verified |
| `0x20` | `00` | host-handled double tap when action is mapped to Translate/`0x02` | verified |

`0x07`/`0x08`/`0x09`/`0x0E` arrived as one clustered sequence ending in two
`caseBattery(level: 60)` events, i.e. the glasses being taken off and put away.
They are lifecycle notifications, not Even AI.

`0x0A` frames were initially mistaken for a pitch-angle channel. A run with
timed, labelled head tilts disproved that: the frames arrive as part of a
periodic `0A`/`09`/`0E` triplet unrelated to head movement. Deliberate tilts
produce discrete `0xF5` events rather than a continuous angle channel; the final
firmware traces established `F5 02`/`F5 03` as the primary pair.

The successful custom-dashboard runs used `F5 02` for head-up and `F5 03` for
head-down, primarily from the right arm. Earlier sessions also observed
`F5 1E`/`F5 1F` around firmware dashboard transitions. Those alternate codes
must not be assumed to be the only physical motion source across firmware
versions.

The firmware can emit `F5 03` within roughly 0.5-3.0 seconds of head-up while a
bitmap is still uploading. This is genuine device traffic, not a parsing
artifact, so the dashboard ignores head-down for 3.5 seconds after an accepted
head-up.

## Head-up mode and head-up action are separate

Two controls that initially appeared equivalent have materially different
behavior:

- Head-up **mode** uses `0x0A`/`0x0B`. Setting the mode to off can suppress the
  `headUp` event itself, preventing the app from detecting the gesture.
- Head-up **action** uses `0x08`. Mapping the action to `None` with
  `08 06 00 00 03 02` suppresses firmware UI while preserving `F5 02`.

Conclusion: never disable the mode to win the display. Keep `0x0A`/`0x0B`
globally suppressed and map only the firmware action to `None` while the custom
dashboard is enabled.

## The head-up mode command is expensive on this firmware

`configureTiltDashboard` probes `0x0A` first, then falls back to `0x0B`. On this
firmware `0x0A` never ACKs and only `0x0B` answers (`cmd=0B code=C9`), so every
configure call burns the full `0x0A` timeout on both arms before succeeding.

Measured cost at navigation start: route planned at `t`, configure ACKs at
`t+5.5 s`/`t+6.2 s`, first bitmap on the glasses at `t+7.9 s`. This was the
entire cause of the "initial map load takes longer than 5 seconds" report. Tilt
configuration must never sit on the path between Start and the first frame.

## Text replaces the bitmap

There is one display surface. Sending a text packet (`0x4E`) during navigation
replaces the map until the next bitmap upload. This is why a double tap, which
maps to "repeat current instruction", makes the map vanish for about a second:
the instruction text takes the surface and the next map upload takes it back.
Any user-facing action during navigation must render into the bitmap rather than
send text.

## Even AI prompt

The “release to finish recording Even AI” overlay is firmware UI, not app text.
Sending `0x0A`/`0x0B` was one way to provoke it and remains forbidden.

The residual intermittent prompt was caused by the firmware action still
assigned to head-up. After both arms acknowledged `08 06 00 00 03 02`, repeated
head-up cycles showed no Even AI or stock dashboard while `F5 02` continued.

`F5 12` was correlated with one earlier prompt and was instrumented as a
possible cause. It later appeared after action suppression without producing
any overlay, proving that the event alone is not sufficient to open Even AI.

## TouchBar actions and Live Captions (2026-08-22)

Left long press is firmware-owned. The glasses draw Even AI before sending
`F5 17`, so clearing with `0x18` after receiving the event can only shorten the
flash. It cannot prevent it.

The documented long-press setting was tested on both arms:

```text
26 06 00 <seq> 07 00
```

Both arms acknowledged it and `F5 17`/`F5 18` remained available, but Even AI
still appeared. The setting is ineffective for suppressing visible Even AI on
this firmware and is not used by the app.

The verified replacement is the host-handled double-tap Translate action:

```text
26 06 00 <seq> 05 02
```

After both arms acknowledge the mapping, double-tapping either TouchBar emits
`F5 20` without stock UI. Live Captions starts from that event. While captions
are active, double tap emits `F5 00`; the app stops the microphone and clears
the lens. This start/stop cycle was repeated from both arms without showing
Even AI.

`0x26` responses are structured. Their meaningful prefix is
`26 06 00 <seq> <subcommand> C9`, potentially followed by padding. ACK routing
must extract the sequence from payload offset 2 and status from payload offset
4; treating payload byte 0 as a generic status causes false timeouts.

## Firmware dashboard override strategy (2026-08)

The stock Even Realities firmware renders its own lens UI on head-up: the native
dashboard, navigation status such as “your route is being generated,” and the
Even AI recording prompt. These strings are **not** produced by this app.

Final verified strategy:

1. When the dashboard is enabled and both arms are connected, map head-up action
   to `None` with `08 06 00 00 03 02`.
2. Preserve raw `F5 02`/`F5 03` motion events.
3. On head-up, send `0x18` and await both arms to remove any residual firmware
   surface.
4. Render a current snapshot and upload it without sending `0x07 01`.
5. Ignore firmware follow-up head-down events for 3.5 seconds.
6. On a later intentional head-down, send `0x18` to clear the custom frame.
7. When the custom dashboard is disabled, restore the default firmware action
   with `08 06 00 00 03 00`.

Pre-latching was useful as an experiment but was not sufficient as the final
strategy: any later `0x18` invalidates the stored frame, and `0x07 01` gives the
firmware dashboard layer ownership again. The verified path uploads directly
after the head-up clear and completes in about one second.

### Power-cycle isolation test

To determine whether firmware messages persist across sessions:

1. Fully power-cycle the glasses (case closed until LEDs indicate off).
2. Launch **only** this app; do not open the official Even Realities app.
3. Head-up before opening the Dashboard screen.

If stock firmware UI still appears, inspect the stored firmware head-up action
and apply the `0x08 ... 0x02` mapping before the first head-up. If it is absent
until a specific app action, trace that action in BLE logs.

## Inbound `0xF6` vendor configuration channel

Observed chunked JSON on command `0xF6` with sub-type `0x06`:

- Wire format: `F6 06 <chunkIndex> <utf8-json-bytes...>`
- Example payload decodes to whitelist registration JSON such as
  `{"whitelist_add": {"application_identifier": "...", "display_name": "..."}}`
- Previously logged as `Unknown cmd=0xF6`; now reassembled in
  `G1VendorConfigReassembler`.

Status: **reassembled in memory**; no outbound control documented yet.

## Experimental dashboard layout (`0x06`)

Community docs place dashboard layout on command `0x06` alongside visibility `0x07`.
`experimentalSendMinimalDashboardLayout()` sends `06 00` for manual hardware trials.
Not invoked automatically; effectiveness unverified.

## Corrected interpretation of `F5 02` and `F5 03`

These codes were initially mapped as `swipeForward` and `swipeBackward`, which
made alternating head-state traffic look like phantom swipes. Reproduction with
labelled physical movement established their actual role on the tested
firmware:

- `F5 02` starts the head-up dashboard flow.
- `F5 03` reports return to level/head-down.

They must not drive navigation step previews. `G1FrameParser.parseStatusResponse`
remains a latent hazard worth tightening: it scans a `0x22` payload for a stray
`0xF5` byte and otherwise treats `payload[0]` as an event code, which can
fabricate gestures from status data.

## Frame freshness on the glasses

The glasses hold the last uploaded bitmap indefinitely, so a skipped upload
looks exactly like a frozen map. Two throttles decide whether an upload happens,
and both were far too coarse for a head-level window where one pixel is about a
metre of ground:

- `NavigationMapScene.uploadSignature` quantized the user position to 1/500 of a
  degree (roughly 200 m) and then formatted it to three decimals (roughly
  110 m), so walking a whole block produced a byte-identical fingerprint and no
  upload.
- `minimalBitmapInterval` allowed at best one head-level refresh every 15 s.

Measured effect: a session whose first frame landed 1.7 s after Start went 54 s
without another upload while the wearer walked, with every logged map window
identical. Now quantized to 12 m with an 8 s floor.

The deeper cause of a stationary map is upstream of the throttles. A 3.5-minute
walking session delivered only **three** location updates to the view model, and
the reported remaining distance moved by 12 m in the wrong direction, so the
fingerprint had nothing new to encode. `RouteTracker` asks for best accuracy with
a 5 m distance filter, which should yield tens of updates over that distance.
Under investigation: automatic pausing, authorization, and main-actor starvation
during the bitmap upload storm are the candidates.

## MapKit snapshot notes

- `MKMapSnapshotter` always burns the Apple Maps logo into the bottom-left of
  the image.
- Cropping that attribution from imagery shown on an external display is not an
  acceptable workaround. The lens renderer therefore uses only app-authored
  route vectors; the attributed MapKit map remains on the phone.
- `MKMapSnapshotOptions.scale` is honored on iOS but ignored on macOS, so the
  offline preview harness must crop by fraction rather than by pixel count.
