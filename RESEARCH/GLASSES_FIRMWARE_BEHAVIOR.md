# G1 Firmware Behavior Notes

Observed on real hardware (dual-arm G1, firmware as shipped mid-2026) while
debugging navigation head-up and display ownership. Every entry below is backed
by NDJSON runtime logs from device sessions; the "confidence" column separates
what the logs prove from what remains inference.

## 0xF5 device event codes

The firmware sends notifications as `0xF5 <code> <value> <18 zero bytes>`. Codes
the app maps (tap/swipe/head) are in `G1DeviceEvent`. Codes observed as
`unknown` during navigation sessions:

| Code | Observed values | Meaning | Confidence |
| --- | --- | --- | --- |
| `0x07` | `00` | display/dashboard surface state, reported single-arm | inferred |
| `0x08` | `00` | wear or case state change, always a left+right pair | inferred |
| `0x09` | `01` | wear or case state change, always a left+right pair | inferred |
| `0x0A` | `18`-`21`, `28`, `32`-`39` | part of a recurring `0A`/`09`/`0E` status triplet spaced about a second apart; not tilt, values do not track head movement | inferred |
| `0x0E` | `01` | charge or case state, immediately precedes `caseBattery` | inferred |

`0x07`/`0x08`/`0x09`/`0x0E` arrived as one clustered sequence ending in two
`caseBattery(level: 60)` events, i.e. the glasses being taken off and put away.
They are lifecycle notifications, not Even AI.

`0x0A` frames were initially mistaken for a pitch-angle channel. A run with
timed, labelled head tilts disproved that: the frames arrive as part of a
periodic `0A`/`09`/`0E` triplet unrelated to head movement, while the deliberate
tilt produced a real `F5 1E` head-up pair instead. Head-up is the discrete event,
not an angle threshold.

Head events arrive as `F5 1E` (up) and `F5 1F` (down), one frame per arm, the
pair landing within about 200 ms. The firmware sends its own head-down roughly
500-700 ms after each head-up, which is genuine `0xF5` traffic rather than a
parsing artifact, so the dwell timer is required. Verified working: a head-up at
one timestamp logged `head-down ignored during overview hold` 500 ms later with
7.5 s remaining, uploaded the overview, and auto-returned to the head-level map
about 8 s later.

## Head-up is firmware-owned, and turning it off costs the event

Two separate device sessions establish the trade-off:

- With firmware head-up left at its default, `headUp` events arrive, but the
  firmware draws its own dashboard over the custom bitmap and dismisses it after
  roughly one second, emitting a `headDown` the app then acts on. Eight `headUp`
  events in one session, each followed by a `headDown` about 1 s later.
- After the app set head-up mode to off (intending to own the surface), the
  session logged **zero** `headUp` events against four `headDown` events across
  four deliberate 3-10 s tilts. Suppressing the feature suppresses its event, so
  the app can no longer detect the tilt at all.

Conclusion: do not disable firmware head-up mode to win the display. Let the
event arrive and absorb the firmware's fast `headDown` with a dwell timer
(`overviewHoldUntil`) instead.

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

The "release to finish recording Even AI" overlay is firmware UI, and no
incoming event announces it. The mic command bytes (`0x0E` primary,
`G1Command.MIC_ON` fallback) are never sent by this app, and the `0x0E`
notifications received are case/charge lifecycle frames, not recording state.

Confirmed cause: the app's own head-up mode probe. The prompt appeared during
the initial load of every session that sent `0x0A`/`0x0B` at startup, and the
session after that probe was removed showed no prompt at all, including when the
side button was pressed. Do not send head-up mode commands on this firmware.

Note that `pressAndHold` currently maps to "end navigation", which collides with
the stock Even AI gesture. Consider remapping.

## Spurious gesture events

Two consecutive sessions each logged exactly 13 `swipeForward` and 13
`swipeBackward` events, plus `doubleTap` and head events, at times the wearer
was not touching the glasses. In the second session the wearer deliberately
touched nothing for a minute and the events kept arriving, alternating direction
at regular intervals. They also arrive interleaved with bitmap upload traffic.

Each one forces a step preview, a re-render, and a BLE upload, which is why the
instruction line appeared to change on its own while the map stayed still: the
phantom swipes were cycling through step previews.

Not a parsing artifact. Frame-level logging shows each one arriving as a clean
`F5 02` or `F5 03` from the right arm only, so the firmware itself reports them.
Across 19 consecutive pairs the direction alternated perfectly, forward then
backward every time, with gaps from 0.2 s to 35 s. Perfect alternation over that
many pairs is not human input; `0x02`/`0x03` behave like a two-state toggle
report on this firmware rather than directional swipes.

Navigation therefore ignores swipe events entirely and step previews stay on the
phone. `G1FrameParser.parseStatusResponse` remains a latent hazard worth
tightening: it scans a `0x22` payload for a stray `0xF5` byte and otherwise
treats `payload[0]` as an event code, which can fabricate gestures from status
data.

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
  the image. The workaround is to request extra height and crop the bottom band
  off before binarizing.
- `MKMapSnapshotOptions.scale` is honored on iOS but ignored on macOS, so the
  offline preview harness must crop by fraction rather than by pixel count.
