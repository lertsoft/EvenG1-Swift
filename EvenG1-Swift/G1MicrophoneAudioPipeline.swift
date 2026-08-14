import Foundation
import Combine
import EvenG1Core
import AVFAudio

@MainActor
final class G1MicrophoneAudioPipeline: ObservableObject {
    enum DecoderMode: String, CaseIterable, Identifiable {
        case pcm16le
        case pcm16be
        case lc3_16k_20b

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .pcm16le:
                return "PCM 16-bit LE"
            case .pcm16be:
                return "PCM 16-bit BE"
            case .lc3_16k_20b:
                return "LC3 (G1 native)"
            }
        }
    }

    @Published var isPlaybackEnabled = false {
        didSet {
            if isPlaybackEnabled == oldValue { return }
            if isPlaybackEnabled {
                do {
                    try startPlaybackEngine()
                } catch {
                    isPlaybackEnabled = false
                    lastError = "Playback start failed: \(error.localizedDescription)"
                }
            } else {
                stopPlaybackEngine()
            }
        }
    }

    @Published var decoderMode: DecoderMode = .lc3_16k_20b {
        didSet {
            if decoderMode == .lc3_16k_20b {
                sampleRate = 16_000
                lastError = nil
            }
            if decoderMode != oldValue {
                let decoder = lc3Decoder
                decodeQueue.async {
                    decoder?.discardPartialFrame()
                }
            }
        }
    }

    var activeLC3FrameBytes: Int {
        decoderMode == .lc3_16k_20b ? G1LC3Decoder.encodedFrameByteCount : 0
    }

    @Published var sampleRate: Double = 16_000 {
        didSet {
            if sampleRate == oldValue { return }
            if isPlaybackEnabled {
                do {
                    try restartPlaybackEngine()
                } catch {
                    isPlaybackEnabled = false
                    lastError = "Playback restart failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @Published private(set) var decodedPacketCount = 0
    @Published private(set) var playedSampleCount = 0
    @Published private(set) var lastError: String?

    private let decodeQueue = DispatchQueue(label: "com.eveng1.mic.decode", qos: .userInitiated)
    private let lc3Decoder = try? G1LC3Decoder()
    private var packetCancellable: AnyCancellable?
    private var player: PCM16PlaybackEngine?

    func bind(to manager: G1BluetoothManager) {
        packetCancellable?.cancel()
        packetCancellable = manager.microphonePackets.sink { [weak self] packet in
            self?.handle(packet: packet)
        }
    }

    func unbind() {
        packetCancellable?.cancel()
        packetCancellable = nil
        let decoder = lc3Decoder
        decodeQueue.async {
            decoder?.discardPartialFrame()
        }
        stopPlaybackEngine()
    }

    func resetStats() {
        decodedPacketCount = 0
        playedSampleCount = 0
        lastError = nil
    }

    private func handle(packet: G1MicrophonePacket) {
        let payload = packet.payload
        let mode = decoderMode

        guard isPlaybackEnabled else { return }

        let decoder = lc3Decoder
        decodeQueue.async { [weak self] in
            do {
                let samples: [Int16]
                switch mode {
                case .lc3_16k_20b:
                    guard let decoder else {
                        throw G1LC3Decoder.DecoderError.setupFailed
                    }
                    samples = try decoder.decode(payload)
                case .pcm16le, .pcm16be:
                    samples = Self.decodePCMSamples(from: payload, mode: mode)
                }

                guard !samples.isEmpty, let self else { return }
                Task { @MainActor in
                    self.enqueueDecodedSamples(samples)
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.lastError = "Microphone decode failed: \(message)"
                }
            }
        }
    }

    private func enqueueDecodedSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        do {
            try player?.enqueue(samples: samples)
            decodedPacketCount += 1
            playedSampleCount += samples.count
        } catch {
            lastError = "Playback enqueue failed: \(error.localizedDescription)"
        }
    }

    private func startPlaybackEngine() throws {
        stopPlaybackEngine()
        let engine = try PCM16PlaybackEngine(sampleRate: sampleRate)
        player = engine
        lastError = nil
    }

    private func stopPlaybackEngine() {
        player?.stop()
        player = nil
    }

    private func restartPlaybackEngine() throws {
        try startPlaybackEngine()
    }

    nonisolated private static func decodePCMSamples(from payload: Data, mode: DecoderMode) -> [Int16] {
        if payload.count < 2 { return [] }

        let sampleCount = payload.count / 2
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        var index = payload.startIndex
        for _ in 0..<sampleCount {
            let low = UInt16(payload[index])
            let high = UInt16(payload[payload.index(after: index)])
            let value: UInt16
            switch mode {
            case .pcm16le:
                value = (high << 8) | low
            case .pcm16be:
                value = (low << 8) | high
            case .lc3_16k_20b:
                return []
            }
            samples.append(Int16(bitPattern: value))
            index = payload.index(index, offsetBy: 2)
        }

        return samples
    }
}

private final class PCM16PlaybackEngine {
    private enum PlaybackError: LocalizedError {
        case formatCreationFailed
        case bufferCreationFailed
        case missingChannelData

        var errorDescription: String? {
            switch self {
            case .formatCreationFailed:
                return "Unable to create PCM audio format"
            case .bufferCreationFailed:
                return "Unable to allocate PCM buffer"
            case .missingChannelData:
                return "PCM channel data unavailable"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init(sampleRate: Double) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw PlaybackError.formatCreationFailed
        }
        self.format = format

        try configureAudioSessionIfNeeded()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()
    }

    isolated deinit {
        stop()
    }

    func enqueue(samples: [Int16]) throws {
        guard !samples.isEmpty else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw PlaybackError.bufferCreationFailed
        }
        buffer.frameLength = frameCount

        if format.isInterleaved {
            guard let channelData = buffer.int16ChannelData else {
                throw PlaybackError.missingChannelData
            }
            let pointer = channelData.pointee
            for (index, sample) in samples.enumerated() {
                pointer[index] = sample
            }
        } else {
            guard let channelData = buffer.int16ChannelData else {
                throw PlaybackError.missingChannelData
            }
            let pointer = channelData[0]
            for (index, sample) in samples.enumerated() {
                pointer[index] = sample
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        playerNode.stop()
        engine.stop()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    private func configureAudioSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers]
        )
        try session.setActive(true)
        #endif
    }
}
