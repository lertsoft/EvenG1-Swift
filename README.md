# EvenG1 Swift

A native Swift companion app for the Even Realities G1 smart glasses, built on a reverse-engineered protocol layer. It connects to both glasses arms over Bluetooth Low Energy, displays text and 1-bit bitmap content, sends app-authored notifications, handles microphone and gesture events, shows nearby NYC subway arrivals, and provides phone-driven navigation guidance with a text fallback for unverified native navigation packets.

The app is organized as a consumer product — a device dashboard, navigation, and heads-up widgets — with the protocol tooling that drove the reverse engineering kept behind a developer toggle. See [App structure](#app-structure).

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
advertising identifier.

## Telemetry

The app reports Real User Monitoring, logs, and crash/hang reports to Datadog
when credentials are present. Without them the SDK is never initialized and
every telemetry call is a no-op, so the app sends nothing to a
developer-operated service by default. Watch for this line in the console to
confirm which mode a build is in:

```
Datadog credentials missing or placeholder. Telemetry running in mock mode.
```

Reporting is enabled by default: the `EvenG1-Swift` target carries a RUM
application ID and client token for a development organization. A RUM client
token is write-only and is designed to ship inside app binaries, so it is safe
to check in — it cannot read data out of Datadog. Point a build at a different
organization by overriding these build settings, from an untracked `.xcconfig`
or on the command line in CI:

| Build setting | Required | Notes |
| --- | --- | --- |
| `DATADOG_CLIENT_TOKEN` | yes | RUM client token, not an API key |
| `DATADOG_APPLICATION_ID` | yes | RUM application ID |
| `DATADOG_SITE` | no | Site identifier (`us5`) or org domain (`us5.datadoghq.com`); defaults to `us1` |
| `DATADOG_ENV` | no | Set to `DEV` in Debug and `prod` in Release |
| `DATADOG_SERVICE` | no | Defaults to the bundle identifier |

`Info.plist` forwards each setting to the app bundle, and blank or unexpanded
values are treated as absent so a half-configured build falls back to mock mode
rather than shipping a bogus credential.

What is collected:

- **RUM views** from `trackDatadogRUMView(name:)` on each tab (`DeviceTab`,
  `NavigateTab`, `AppsTab`). Automatic SwiftUI
  view detection is deliberately off: it does not yet suppress views tracked by
  the modifier, so enabling both would report every screen twice.
- **RUM actions** automatically, plus custom hardware and experiment events.
- **RUM resources** for the MTA GTFS-Realtime and station requests, via
  `URLSession.dataReportingRUMResource(for:)`. These are reported manually because
  `URLSessionInstrumentation` matches requests by the class of the session delegate,
  and these clients call async `data(for:)` on a delegate-less session.
- **Logs** at every severity from the Bluetooth, experiment, navigation,
  transit, notification, navigation, and search text is deliberately excluded.
- **Handled errors** from recoverable navigation, transit, search, audio, and
  Bluetooth failures, reported to both Logs and RUM Error Tracking.
- **Crashes, memory warnings, watchdog terminations, and app hangs**.

Feature flags and experiments are evaluated locally, from mock values or the
caller's default; only the resulting evaluations are sent to Datadog, so they
correlate with sessions and errors. Serving real values is still an open task.
The `DatadogFlags` module in SDK 3.x can deliver them through `FlagsClient`,
which would replace the mock table in `FeatureFlagManager`.

Enabling telemetry means the app collects usage data, which changes what you
must declare in `PrivacyInfo.xcprivacy` and in App Store privacy answers.
Revisit both before shipping a build with credentials baked in.

## Verification

This project is iOS-only (Datadog RUM requires UIKit). Run the full test suite from Xcode (**Product → Test**) or from the CLI with an iPhone Simulator destination.

Run all verification tests (unit + UI):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project EvenG1-Swift.xcodeproj \
  -scheme EvenG1-Swift \
  -testPlan Verification \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

Run only the core unit tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project EvenG1-Swift.xcodeproj \
  -scheme EvenG1-Swift \
  -testPlan Verification \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EvenG1CoreTests \
  CODE_SIGNING_ALLOWED=NO
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
- `RESEARCH`: protocol evidence, unresolved assumptions, and the physical-device navigation validation matrix.

The G1 uses two BLE peripherals, one per arm, over the Nordic UART service. Commands normally flow to the left arm and then the right after acknowledgment. Explicitly side-specific operations, such as microphone activation, use the documented side-specific path first.

## App structure

Three consumer tabs, with every engineering surface behind a developer toggle:

| Tab | Contents |
| --- | --- |
| **Device** (`EvenG1-Swift/Device`) | Connection hero with per-arm battery, one connect action, silent-mode and brightness controls, Glasses Configuration, Support & Diagnostics |
| **Navigate** (`EvenG1-Swift/Navigate`) | Search, route preview, turn-by-turn guidance, confirmed trip cancellation, and an optional on-screen preview of the glasses HUD |
| **Heads-Up** (`EvenG1-Swift/Apps`) | Transit arrivals, app-authored notifications, and notes/prompts, each as a self-contained widget |

## Apple-native intelligence and voice

- **Translate (iOS 18+)** decodes the G1's native LC3 microphone stream, uses Apple Speech recognition, translates finalized phrases with Apple's on-device Translation framework, and pages the result on the glasses. Required language assets are prepared through the system download flow.
- **EvenG1 Assistant (iOS 26+)** starts when the user holds the glasses side button and submits the finalized transcript to Apple's on-device Foundation Models framework. On older or ineligible devices, EvenG1 keeps Apple speech/translation features but reports why general AI answers are unavailable.
- **Siri and Shortcuts** expose navigation to a saved favorite, next-train refresh, translation start/stop, and sending a note to the glasses through App Intents. iOS opens EvenG1 for actions that need Bluetooth, location, speech permission, or a foreground translation session.
- Voice audio, transcripts, translations, prompts, and answers are not included in telemetry.

MapKit remains the embedded navigation provider. Walking and cycling use Apple's route server and retain the selected route in memory so active GPS guidance can continue through a temporary network loss. Embedded MapKit only exposes public-transit ETA calculations—not Apple Maps' complete transit itinerary—so the Navigate tab labels transit as ETA-only and directs detailed NYC arrival work to the existing MTA realtime experience.

`Device > Support & Diagnostics` exports a single text report — connection state,
log ring buffer, gesture events, and navigation trace — for troubleshooting, and
hosts the **Developer Mode** toggle. Enabling it adds `Device > Developer Tools`
with the raw UART log and event inspector, the navigation transport trace and its
`.jsonl` evidence export, microphone and LC3 codec counters, text-transport
fixtures, and a reference for the vendor byte commands. The flag is persisted but
forced off under `--ui-testing` so UI tests always start from a consumer build.
The notification mirror's enable flag behaves the same way.

`GlassesHUDPreview` (`EvenG1-Swift/Shared`) renders content at the display's real
576×135 pixel size, so previews wrap and truncate the way the glasses will. The
transit widget previews the exact bitmap it sends by sharing
`MTABitmapRenderer.renderImage(page:)` with the transport path.

Connection is automatic: the app restores the last known pair as soon as the
Bluetooth radio reports ready, so `connectToPreferredGlasses()` only has to fall
back to scanning when no pair is remembered.

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
