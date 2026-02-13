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
- `0x17`: start Even AI flow
- `0x18`: stop Even AI recording
- `0x02` / `0x03`: head up/down in several implementations
- `0x08`, `0x0B`, `0x0E`, `0x0F`: case state and battery-related events (Mentra/Fahrplan usage)

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
- Stream from glasses: `0xF1 <seq> <audio bytes...>` (LC3 in demo/community implementations)
- Practical behavior in community repos:
  - mic control sent to right side for reliability in some cases

Source examples:
- `EvenDemoApp-main/README.md`
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`

## 7) Bitmap Upload (0x15 / 0x20 / 0x16)

Canonical sequence:

1) Split BMP into 194-byte chunks
2) Send each chunk with `0x15` and index
3) First chunk includes address bytes `00 1C 00 00`
4) Send end packet: `0x20 0D 0E`
5) Send CRC packet: `0x16 <crc bytes>`

CRC details:

- Repos mention CRC32-XZ / Crc32Xz in big-endian byte order for transmission.
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

Source examples:
- `EvenDemoApp-main/lib/services/proto.dart`
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`
- `MentraOS-main/mobile/modules/core/android/src/main/java/com/mentra/core/sgcs/G1.java`

## 9) Dashboard / Hardware / Navigation Commands Seen In Practice

- Dashboard layout/show families: `0x06`, `0x26`
- Head-up angle: `0x0B`
- Silent mode: `0x03`
- Navigation control packets via `0x0A`

Source examples:
- `MentraOS-main/mobile/modules/core/ios/Source/sgcs/G1.swift`
