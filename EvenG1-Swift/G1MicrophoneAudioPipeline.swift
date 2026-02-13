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
                return "LC3 (16k, 20B)"
            }
        }
    }

    enum LC3FrameSize: Int, CaseIterable, Identifiable {
        case bytes20 = 20
        case bytes40 = 40

        var id: Int { rawValue }

        var displayName: String {
            "\(rawValue) bytes/frame"
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
            }
            lc3DecoderBridge?.reset()
            if decoderMode != .lc3_16k_20b {
                lc3DecoderBridge = nil
                lc3DecoderConfig = nil
            }
        }
    }

    @Published var lc3AutoFrameSize = true {
        didSet {
            if lc3AutoFrameSize == oldValue { return }
            lc3DecoderBridge?.reset()
            lc3DecoderBridge = nil
            lc3DecoderConfig = nil
        }
    }

    @Published var lc3FrameSize: LC3FrameSize = .bytes40 {
        didSet {
            if lc3FrameSize == oldValue { return }
            lc3DecoderBridge?.reset()
            lc3DecoderBridge = nil
            lc3DecoderConfig = nil
        }
    }

    @Published private(set) var activeLC3FrameBytes = 40

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
    private var packetCancellable: AnyCancellable?
    private var player: PCM16PlaybackEngine?
    private var lc3DecoderBridge: G1LC3DecoderBridge?
    private var lc3DecoderConfig: (frameBytes: Int, sampleRate: Int, frameDurationUs: Int)?

    func bind(to manager: G1BluetoothManager) {
        packetCancellable?.cancel()
        packetCancellable = manager.microphonePackets.sink { [weak self] packet in
            self?.handle(packet: packet)
        }
    }

    func unbind() {
        packetCancellable?.cancel()
        packetCancellable = nil
        stopPlaybackEngine()
    }

    func resetStats() {
        decodedPacketCount = 0
        playedSampleCount = 0
        lastError = nil
    }

    private func handle(packet: G1MicrophonePacket) {
        guard isPlaybackEnabled else { return }
        let payload = packet.payload
        let mode = decoderMode
        let selectedSampleRate = Int(sampleRate)
        let selectedFrameBytes = resolvedLC3FrameBytes(forPayloadByteCount: payload.count)
        if mode == .lc3_16k_20b {
            let lc3Decoder = ensureLC3Decoder(frameBytes: selectedFrameBytes, sampleRate: selectedSampleRate)
            let pcmData = lc3Decoder.decodeChunk(payload)
            let samples = Self.samplesFromPCM16Data(pcmData)
            enqueueDecodedSamples(samples, frameBytes: selectedFrameBytes)
            return
        }

        decodeQueue.async { [weak self] in
            let samples = Self.decodeSamples(from: payload, mode: mode)
            guard !samples.isEmpty else { return }
            guard let self else { return }
            Task { @MainActor in
                self.enqueueDecodedSamples(samples, frameBytes: selectedFrameBytes)
            }
        }
    }

    private func enqueueDecodedSamples(_ samples: [Int16], frameBytes: Int) {
        guard !samples.isEmpty else { return }
        do {
            try player?.enqueue(samples: samples)
            decodedPacketCount += 1
            playedSampleCount += samples.count
            activeLC3FrameBytes = frameBytes
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
        lc3DecoderBridge?.reset()
        lc3DecoderBridge = nil
        lc3DecoderConfig = nil
    }

    private func restartPlaybackEngine() throws {
        try startPlaybackEngine()
    }

    nonisolated private static func decodeSamples(from payload: Data, mode: DecoderMode) -> [Int16] {
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

    nonisolated private static func samplesFromPCM16Data(_ data: Data) -> [Int16] {
        if data.count < 2 { return [] }
        let sampleCount = data.count / 2
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        var index = data.startIndex
        for _ in 0..<sampleCount {
            let low = UInt16(data[index])
            let high = UInt16(data[data.index(after: index)])
            samples.append(Int16(bitPattern: (high << 8) | low))
            index = data.index(index, offsetBy: 2)
        }
        return samples
    }

    private func ensureLC3Decoder(frameBytes: Int,
                                  sampleRate: Int,
                                  frameDurationUs: Int = 10_000) -> G1LC3DecoderBridge {
        if let lc3DecoderBridge,
           let lc3DecoderConfig,
           lc3DecoderConfig.frameBytes == frameBytes,
           lc3DecoderConfig.sampleRate == sampleRate,
           lc3DecoderConfig.frameDurationUs == frameDurationUs {
            return lc3DecoderBridge
        }

        lc3DecoderBridge?.reset()
        let bridge = G1LC3DecoderBridge(
            frameBytes: UInt(frameBytes),
            sampleRate: Int32(sampleRate),
            frameDurationUs: Int32(frameDurationUs)
        )
        lc3DecoderBridge = bridge
        lc3DecoderConfig = (frameBytes: frameBytes, sampleRate: sampleRate, frameDurationUs: frameDurationUs)
        return bridge
    }

    private func resolvedLC3FrameBytes(forPayloadByteCount byteCount: Int) -> Int {
        if !lc3AutoFrameSize {
            return lc3FrameSize.rawValue
        }

        if byteCount > 0, byteCount % LC3FrameSize.bytes40.rawValue == 0 {
            return LC3FrameSize.bytes40.rawValue
        }

        if byteCount > 0, byteCount % LC3FrameSize.bytes20.rawValue == 0 {
            return LC3FrameSize.bytes20.rawValue
        }

        return lc3FrameSize.rawValue
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

    deinit {
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
    }

    private func configureAudioSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        )
        try session.setActive(true)
        #endif
    }
}
