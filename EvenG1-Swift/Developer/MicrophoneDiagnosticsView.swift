import SwiftUI
import EvenG1Core

/// Live microphone transport and LC3 codec counters. Developer-only: none of
/// these numbers mean anything to someone just wearing the glasses.
struct MicrophoneDiagnosticsView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @StateObject private var micAudioPipeline = G1MicrophoneAudioPipeline()

    var body: some View {
        Form {
            if bluetoothManager.connectionState != .fullyConnected {
                Section {
                    Label("Connect glasses to capture audio", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Transport") {
                LabeledContent("State") {
                    Text(bluetoothManager.microphoneState.displayName)
                        .font(.subheadline.monospaced())
                }

                LabeledContent("Packets") {
                    Text("\(bluetoothManager.microphoneStats.packetCount)")
                        .monospacedDigit()
                }

                LabeledContent("Bytes") {
                    Text("\(bluetoothManager.microphoneStats.byteCount)")
                        .monospacedDigit()
                }

                LabeledContent("Last Seq") {
                    if let sequence = bluetoothManager.microphoneStats.lastSequence {
                        Text("\(sequence)")
                            .monospacedDigit()
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Playback Monitor", isOn: $micAudioPipeline.isPlaybackEnabled)
                    .disabled(bluetoothManager.connectionState != .fullyConnected)

                Picker("Decoder", selection: $micAudioPipeline.decoderMode) {
                    ForEach(G1MicrophoneAudioPipeline.DecoderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!micAudioPipeline.isPlaybackEnabled)

                Stepper(
                    "Playback Rate: \(Int(micAudioPipeline.sampleRate)) Hz",
                    value: $micAudioPipeline.sampleRate,
                    in: 8_000...48_000,
                    step: 1_000
                )
                .disabled(!micAudioPipeline.isPlaybackEnabled || micAudioPipeline.decoderMode == .lc3_16k_20b)
            } header: {
                Text("Decoder")
            } footer: {
                Text("G1 microphone audio is decoded as vendor-specified 20-byte LC3 frames at 16 kHz. PCM modes remain available only for protocol diagnostics.")
            }

            Section("Codec") {
                LabeledContent("Decoded Packets") {
                    Text("\(micAudioPipeline.decodedPacketCount)")
                        .monospacedDigit()
                }

                LabeledContent("Played Samples") {
                    Text("\(micAudioPipeline.playedSampleCount)")
                        .monospacedDigit()
                }

                LabeledContent("Active LC3 Frame") {
                    if micAudioPipeline.activeLC3FrameBytes > 0 {
                        Text("\(micAudioPipeline.activeLC3FrameBytes) bytes")
                            .monospacedDigit()
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = micAudioPipeline.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { _ = await bluetoothManager.startMicrophone() }
                } label: {
                    Label("Start Capture", systemImage: "mic.fill")
                }
                .disabled(bluetoothManager.connectionState != .fullyConnected || isMicrophoneBusyOrStreaming)

                Button {
                    Task { _ = await bluetoothManager.stopMicrophone() }
                } label: {
                    Label("Stop Capture", systemImage: "mic.slash")
                }
                .disabled(bluetoothManager.connectionState != .fullyConnected || isMicrophoneIdleOrStopping)

                Button {
                    bluetoothManager.resetMicrophoneStats()
                    micAudioPipeline.resetStats()
                } label: {
                    Label("Reset Counters", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Microphone")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            micAudioPipeline.bind(to: bluetoothManager)
        }
        .onDisappear {
            micAudioPipeline.unbind()
        }
    }

    private var isMicrophoneBusyOrStreaming: Bool {
        switch bluetoothManager.microphoneState {
        case .starting, .streaming:
            return true
        case .idle, .stopping, .failed:
            return false
        }
    }

    private var isMicrophoneIdleOrStopping: Bool {
        switch bluetoothManager.microphoneState {
        case .idle, .stopping:
            return true
        case .starting, .streaming, .failed:
            return false
        }
    }
}
