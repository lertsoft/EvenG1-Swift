# G1 Protocol Notes (Cross-Repo)

This file captures concrete command-level behaviors validated across local repos.

## 1) BLE Topology and Discovery

- Device naming pattern includes left/right markers:
  - `_L_` for left arm
  - `_R_` for right arm
- Common discovery behavior:
  - scan all BLE peripherals
  - filter by name containing `Even G1` and side marker
  - connect both sides, then initialize each

Source examples:
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`

## 2) Command / Response Core

- ACK success: `0xC9`
- NACK failure: `0xCA`
- CONTINUE: `0xCB` (seen for some command paths)
- Init command: `0x4D 0x01`
- `0x26` hardware-setting responses are structured rather than one-byte ACKs:
  - meaningful prefix: `26 06 00 <seq> <subcommand> C9`
  - after removing the command byte, sequence is payload offset 2 and status is
    payload offset 4
  - responses may include trailing padding
  - matching only `(side, command)` or reading payload offset 0 as status causes
    false timeouts for sequence-keyed waiters

Source examples:
- `MentraOS-main/mobile/modules/core/ios/Source/utils/Enums.swift`
- `EvenDemoApp-main/lib/services/proto.dart`

## 3) Heartbeat and Battery

### Heartbeat variants observed

- Variant A (short): `0x25 <seq>`
  - Used in MentraOS iOS path
- Variant B (extended): `0x25 0x06 0x00 <seq> 0x04 <seq>`
  - Used in EvenDemo/Fahrplan-style implementations

### Battery

- Request: `0x2C 0x01`
- Common response shape: `0x2C 0x66 <battery%> <flags> <v_low> <v_high> ...`

Source examples:
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`
- `EvenDemoApp-main/lib/services/proto.dart`

## 4) Device Events (0xF5)

Important subcommands repeatedly used:

- `0x00`: exit / double tap behavior
- `0x01`: page control / tap behavior
- `0x17`: left TouchBar hold threshold / start stock Even AI flow
- `0x18`: left TouchBar release / stop stock Even AI recording
- `0x20`: host-handled double-tap action; verified after mapping double tap to
  Translate with `26 06 00 <seq> 05 02`
- `0x02` / `0x03`: head up/down in several implementations
- `0x08`, `0x0B`, `0x0E`, `0x0F`: case state and battery-related events (Mentra/Fahrplan usage)

On the tested firmware, `F5 20` produces no stock UI. `F5 00` is emitted when
double-tapping out of an active text/captions surface. The same physical action
may be reported by both arms, so consumers must coalesce duplicate stop events.

Source examples:
- `EvenDemoApp-main/lib/ble_manager.dart`
- `MentraOS-main/mobile/modules/core/ios/Source/utils/Enums.swift`

## 5) Text / AI Result Display (0x4E)

Packet shape used across repos:

- `[0x4E, seq, totalPkts, pktIdx, screenStatus, charPosHi, charPosLo, pageNum, maxPageNum, ...utf8Payload]`

Common screenStatus values:

- `0x31`: new content + AI displaying
- `0x40`: AI display complete
- `0x50`: AI manual paging mode
- `0x60`: AI network error
- `0x70`/`0x71`: text display mode (repo-dependent naming, functionally similar)

Payload chunk sizes seen:

- up to 176 bytes per packet payload (when 4-9 bytes of headers are reserved)
- 191-byte payload variant also exists in EvenDemo's AI packet helper

Source examples:
- `EvenDemoApp-main/lib/services/evenai_proto.dart`
- `EvenDemoApp-main/lib/services/proto.dart`
- `MentraOS-main/mobile/modules/core/ios/Source/utils/G1Text.swift`

## 6) Microphone Flow

- Start mic: `0x0E 0x01`
- Stop mic: `0x0E 0x00`
- Stream from glasses: `0xF1 <seq> <audio bytes...>`
- Vendor decoder parameters: LC3, 20 encoded bytes/frame, 10 ms/frame,
  16 kHz mono output (160 signed 16-bit PCM samples/frame)
- Practical behavior in community repos:
  - mic control sent to right side for reliability in some cases
  - this app's Live Captions hardware runs proved the left arm reliable for
    repeated `0x0E 01`/`0x0E 00` start-stop cycles; preferring left avoided the
    earlier right-arm timeout/fallback sequence

Source examples:
- `EvenDemoApp-main/README.md`
- `EvenDemoApp-main/ios/Runner/PcmConverter.m`
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`

## 7) Bitmap Upload (0x15 / 0x20 / 0x16)

Canonical sequence:

1) Serialize a complete Windows 3.x 1-bit BMP and split it into 194-byte chunks
2) Send each chunk with `0x15` and a one-byte index
3) First chunk includes address bytes `00 1C 00 00`
4) Send end packet: `0x20 0D 0E`
5) Send CRC packet: `0x16 <crc bytes>`

CRC details:

- CRC32-XZ is calculated over the four-byte storage address followed by the complete BMP file, then transmitted in big-endian byte order.
- Multiple implementations exist; some use explicit CRC32-XZ table logic, some use standard CRC32 fallback.

Source examples:
- `EvenDemoApp-main/lib/controllers/bmp_update_manager.dart`
- `EvenDemoApp-main/README.md`
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`

## 8) Notifications and Whitelist JSON

### Whitelist / app list setup
- Command `0x04`
- JSON split into chunks
- chunk header usually `[cmd, totalChunks, chunkIndex]`

### Notification send
- Command `0x4B`
- JSON payload under `ncs_notification`
- chunk header pattern typically `[0x4B, msgId, totalChunks, chunkIndex]`
- EvenG1 Swift exposes typed whitelist/notification builders and sends these
  vendor transactions through the left arm with bounded packet counts,
  acknowledgements, and retries. The app includes a manual test sender; iOS
  does not expose other apps' Notification Center contents for arbitrary relay.

Source examples:
- `EvenDemoApp-main/lib/services/proto.dart`
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`
- `MentraOS-main/mobile/modules/core/android/src/main/java/com/mentra/core/sgcs/G1.java`

## 9) Dashboard / Hardware / Navigation Commands Seen In Practice

- Dashboard layout/show families: `0x06`, `0x07`
- Head-up action mapping: `0x08 0x06 0x00 0x00 0x03 <action>`
  - `action=0x02`: no firmware UI action; preserves `F5 02` motion events
  - `action=0x00`: restore the default firmware action
- Head-up behavior/angle: `0x0A` / `0x0B` (firmware-dependent)
  - On the tested mid-2026 firmware these commands are slow, can trigger Even
    AI, and mode-off can suppress motion events. The custom dashboard globally
    blocks them and uses `0x08` instead.
- Silent mode: `0x03`
- Raster/display position settings: `0x26` (length, sequence, action, enable, height, distance)
- Touch-action settings on the `0x26` family:
  - double-tap action: `26 06 00 <seq> 05 <action>`
  - `action=0x02`: host-handled Translate; emits `F5 20` without stock UI
  - `action=0x00`: no action / close active feature
  - long-press action probe: `26 06 00 <seq> 07 00`
  - the long-press probe ACKed on both arms and preserved `F5 17`/`F5 18`, but
    did **not** suppress the visible Even AI overlay on the tested firmware
- Legacy experimental navigation packets used `0x0A`; this inferred payload
  family remains hardware-gated and must not be enabled on the verified
  dashboard path.

The verified Live Captions control maps both arms to double-tap Translate,
routes `F5 20` to start, and routes active-surface `F5 00` to stop. See
[`LIVE_CAPTIONS_GESTURE_CONTROL.md`](LIVE_CAPTIONS_GESTURE_CONTROL.md) for the
full failed-attempt chronology and command sequences.

Source examples:
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`
- [EvenDemoApp issue #33 (`0x26` display settings)](https://github.com/even-realities/EvenDemoApp/issues/33)
