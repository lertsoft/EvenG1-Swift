# EvenG1 Swift

An experimental native Swift app for understanding and extending the Even Realities G1 smart-glasses protocol. The project connects to both glasses arms over Bluetooth Low Energy, displays text and 1-bit bitmap content, sends vendor-formatted test notifications, handles microphone and gesture events, shows nearby NYC subway arrivals, and provides phone-driven navigation guidance with a text fallback for unverified native navigation packets.

This is a reverse-engineering project, not an official Even Realities product. Protocol behavior can vary by firmware; validate experimental commands on hardware before relying on them.

## Requirements

- Xcode 26.2 or newer
- iOS 17.6 or newer
- Swift 6.2 toolchain (included with Xcode 26.2)
- A physical iPhone for Bluetooth and glasses validation

## Setup

1. Clone the repository and open `EvenG1-Swift.xcodeproj`.
2. Select your Apple development team and an iPhone destination, then run the `EvenG1-Swift` scheme.

MTA's current public subway and service-alert GTFS-Realtime feeds do not
require an API key. The app therefore works without embedding a credential in
its bundle.

The app requests Bluetooth and when-in-use location access. The Simulator is useful for compilation and UI work, but Core Bluetooth behavior must be tested on a physical device.

The bundled privacy manifest declares app-only `UserDefaults` usage under
Apple's approved `CA92.1` reason. The app does not use tracking domains or an
advertising identifier, and it does not send analytics to a developer-operated
service.

## Verification

Run the core package tests:

```sh
swift test
```

Build the iOS app without code signing:

```sh
xcodebuild \
  -project EvenG1-Swift.xcodeproj \
  -scheme EvenG1-Swift \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Architecture

- `Sources/EvenG1Core`: reusable Bluetooth, protocol, bitmap, notification, navigation-transport, and MTA GTFS-Realtime logic.
- `Sources/CLibLC3`: vendored Google liblc3 1.1.3 decoder source (Apache-2.0) used for the G1 microphone's native 20-byte LC3 frames.
- `EvenG1-Swift`: SwiftUI application, location/search/routing integration, station preferences, bitmap rendering, and microphone audio pipeline.
- `Tests/EvenG1CoreTests`: deterministic protocol, transport fallback, GTFS parsing, station-cache, and transit-selection tests.
- Navigate's waveform diagnostics sheet previews the current transport/session
  state and exports bounded navigation traces as chronological `.jsonl` evidence.
- `RESEARCH`: protocol evidence, unresolved assumptions, and the physical-device navigation validation matrix.

The G1 uses two BLE peripherals, one per arm, over the Nordic UART service. Commands normally flow to the left arm and then the right after acknowledgment. Explicitly side-specific operations, such as microphone activation, use the documented side-specific path first.

## Reference documentation

- [Even Realities EvenDemoApp](https://github.com/even-realities/EvenDemoApp) for the vendor-published G1 protocol examples, including text, bitmap, microphone, and dual-arm ordering
- [Google liblc3](https://github.com/google/liblc3) for the maintained Apache-2.0 LC3 codec implementation used by the microphone playback pipeline
- [EvenDemoApp display-settings guidance](https://github.com/even-realities/EvenDemoApp/issues/33) for the `0x26` raster height/distance packet
- [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth) for discovery, connection, privacy, and lifecycle requirements
- [Apple MapKit](https://developer.apple.com/documentation/mapkit) for search, routing, overlays, and map items
- [Apple Core Location](https://developer.apple.com/documentation/corelocation) for authorization and location updates
- [Apple privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) for required-reason API declarations
- [MTA developer resources](https://www.mta.info/developers), [MTA GTFS documentation](https://github.com/nymta/gtfs-documentation), and the official [MTA Subway Stations dataset](https://data.ny.gov/Transportation/MTA-Subway-Stations/39hk-dx4f/about_data)
- [Socrata paging documentation](https://dev.socrata.com/docs/paging.html) for explicit Open Data query ordering and limits
- [GTFS Realtime reference](https://gtfs.org/documentation/realtime/reference/) and [SwiftProtobuf](https://github.com/apple/swift-protobuf)

See `RESEARCH/PROTOCOL_NOTES.md` for byte-level notes and `RESEARCH/NAVIGATION_VALIDATION_MATRIX.md` for the remaining hardware checks.
