# Even G1 Reverse Engineering App

This repo is a work in progress attempt at building my own [Even Relaities G1](https://www.evenrealities.com/g1) smart glasses app. I am reverse engineering the Even G1 protocolto understand how they work and build my own app with my own UX and features.

## Repos that were helpful

1. [`EvenDemoApp-main`](https://github.com/even-realities/EvenDemoApp) - Flutter demo from Even Realities themselves with protocol examples
2. `fahrplan-main` - community reverse-engineered app with many working flows
3. [`MentraOS-main`](https://github.com/Mentra-Community/MentraOS) -  A big Open Source smart-glasses platform and OS with active G1 iOS/Android implementations

## Quick Architecture Summary

- G1 is dual-radio BLE: one left arm and one right arm.
- Most commands are sent to both sides; some are right-only (mic control is commonly right-side in real implementations).
- BLE transport is Nordic UART service:
  - Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
  - TX (write): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
  - RX (notify): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Core ACKs:
  - `0xC9` success
  - `0xCA` failure
  - `0xCB` continue (seen in some flows like whitelist)

## Key Protocol Flows Confirmed Across Repos

- Init: `0x4D 0x01`
- Heartbeat: two observed patterns:
  - Short pattern: `0x25 <seq>` (Mentra iOS)
  - Extended pattern: `0x25 0x06 0x00 <seq> 0x04 <seq>` (EvenDemo/Fahrplan style)
- Battery: request `0x2C 0x01`, response includes battery percent (commonly `2C 66 <percent> ...`)
- Text/AI display: `0x4E` packets with header fields for sequence, page and display state
- Mic control: `0x0E 0x01` on, `0x0E 0x00` off
- Mic audio stream from glasses: `0xF1`
- Device events from glasses: `0xF5` subcommands (touch, case, AI trigger, etc.)
- Bitmap upload flow:
  1) stream chunks with `0x15` (first chunk includes address bytes `00 1C 00 00`)
  2) end with `0x20 0D 0E`
  3) CRC check with `0x16 <crc32-xz>`
- Notifications:
  - setup/allowlist via `0x04` JSON chunking
  - push notification payload via `0x4B` JSON chunking
