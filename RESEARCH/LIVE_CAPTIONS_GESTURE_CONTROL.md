# Live Captions Gesture Reverse Engineering

## Scope

This note records the real-hardware investigation completed on 2026-08-22 for
starting and stopping offline Live Captions from the Even G1 TouchBars without
showing the stock Even AI overlay.

The tested device was a dual-arm G1 on the mid-2026 firmware used throughout
the other research notes. Conclusions are based on BLE command/event logs and
wearer-observed lens behavior.

## Original behavior

The first implementation reused the stock left-arm long press:

1. The glasses emitted `F5 17` when the hold threshold was reached.
2. The firmware immediately displayed “release to finish recording Even AI.”
3. The app reacted with `0x18` to clear the firmware surface.
4. On `F5 18` release, the app started its own microphone and captions.

This worked functionally, but Even AI always flashed first. The app cannot win
that race: the firmware renders its surface before delivering `F5 17` to the
phone.

Stopping initially reused another hold. While text owned the display, firmware
behavior made this awkward: the user first had to double-tap out of the active
surface and then hold. Repeated start/stop requests could also overlap
microphone commands and destabilize the pipeline.

## Failed long-press suppression

Community protocol notes describe hardware-setting subcommand `0x07` as
“Enable/Disable Long Press Action.” The app tested:

```text
26 06 00 <seq> 07 00
```

Both arms returned successful structured `0x26` responses. The host continued
to receive `F5 17` and `F5 18`, but the stock Even AI overlay still appeared.

Therefore, on this firmware:

- subcommand `0x07` is accepted;
- value `0x00` does not suppress the visible left-long-press Even AI flow;
- it must not be presented as a solution to firmware UI ownership.

The experimental override was removed.

## Structured `0x26` ACK finding

The first suppression attempt appeared to time out on the left arm and never
reached the right. The command was valid; the generic ACK parser was wrong.

A hardware-setting response has this meaningful prefix:

```text
26 06 00 <seq> <subcommand> C9
```

The frame may include trailing padding. After removing command byte `0x26`, the
transaction sequence is at payload offset 2 and status is at offset 4. Treating
payload offset 0 (`0x06`, the packet length) as generic status loses the
sequence, so a waiter keyed by `(side, command, sequence)` never resolves.

`G1BluetoothManager.routeAckIfNeeded` now parses `0x26` separately. This was
verified with successful matching responses from both arms.

## Successful host-handled double tap

The `0x26` hardware-settings family also controls the double-tap action. Live
Captions maps it to the firmware's host-handled Translate slot:

```text
26 06 00 <seq> 05 02
```

Both arms acknowledge the setting. A double tap on either TouchBar then emits:

```text
F5 20 00 ...
```

No firmware Translate screen, dashboard, or Even AI overlay appears. `F5 20`
is therefore a host action notification, not a request the firmware renders
locally.

The app maps this event to `G1Event.actionDoubleTap` and starts captions. While
caption text is active, a double tap closes the active firmware text surface
and emits ordinary `F5 00` events, which the app maps to `G1Event.doubleTap`
and uses to stop captions.

## Verified interaction

- Double-tap either TouchBar while idle: start Live Captions.
- Speak: audio is captured from the selected glasses microphone and translated
  text is sent with `0x4E`.
- Double-tap either TouchBar while active: stop the microphone and clear the
  lens.
- Repeat: a new session starts successfully.
- No stock Even AI overlay appears during either captions action.

Physical double taps can be reported by both arms. Stop is guarded so duplicate
events cannot run shutdown twice. Start is also latched while language/session
preparation is in progress.

## Command and event sequence

At connection, when TouchBar caption control is enabled:

```text
TX L  26 06 00 <seq> 05 02
RX L  26 06 00 <seq> 05 C9 ...
TX R  26 06 00 <seq> 05 02
RX R  26 06 00 <seq> 05 C9 ...
```

Start:

```text
RX     F5 20 ...
TX     18                    clear residual display
TX L   0E 01                 start preferred left microphone
TX L/R 07 01                 claim/show text surface
TX L/R 4E ...                “Listening…” and translated text
```

Stop:

```text
RX L/R F5 00 ...             duplicate close/double-tap events are possible
TX L   0E 00                 stop microphone
TX L/R 18                    clear display
```

When TouchBar caption control is disabled, the app restores double-tap action
value `0x00`.

## Design conclusions

1. Do not use left long press for an app-owned feature that must avoid stock
   Even AI; reactive `0x18` can only shorten the flash.
2. An acknowledged firmware setting is not proof of its advertised semantics.
   Validate both emitted events and visible lens behavior.
3. Prefer host-handled firmware action slots such as `F5 20` when available.
4. Parse structured command responses by their actual sequence/status offsets;
   do not force every command family through a one-byte generic ACK model.
5. Treat paired-arm gesture reports as one physical action and make start/stop
   lifecycle operations idempotent.
