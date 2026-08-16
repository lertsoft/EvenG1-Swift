import AVFAudio
import Foundation
import Speech

@MainActor
final class AppleSpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case permissionDenied
        case unavailable
        case audioFormatUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Speech recognition permission is required."
            case .unavailable:
                return "Speech recognition is unavailable for this language."
            case .audioFormatUnavailable:
                return "The glasses audio format could not be created."
            }
        }
    }

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var latestTranscript = ""
    private var onUpdate: ((String, Bool) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var recognitionGeneration = 0

    var supportsOfflineRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition == true
    }

    func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            return true
        }

        // Speech invokes this completion on a framework-owned queue. Keeping
        // it inside this @MainActor method makes Swift 6 infer a main-actor
        // isolated completion, which traps when Speech calls it off-main.
        return await Self.requestAuthorizationFromSpeechFramework()
    }

    nonisolated private static func requestAuthorizationFromSpeechFramework() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start(locale: Locale,
               preferOffline: Bool = true,
               onUpdate: @escaping (String, Bool) -> Void,
               onFailure: @escaping (String) -> Void) async throws {
        cancel()
        guard await requestAuthorization() else {
            throw TranscriberError.permissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if preferOffline, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.recognizer = recognizer
        self.request = request
        self.onUpdate = onUpdate
        self.onFailure = onFailure
        latestTranscript = ""
        recognitionGeneration &+= 1
        let generation = recognitionGeneration

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionGeneration == generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.latestTranscript = text
                    self.onUpdate?(text, result.isFinal)
                    if result.isFinal {
                        self.completeFinalTranscript()
                        return
                    }
                }

                if let error {
                    if self.finalContinuation != nil {
                        self.completeFinalTranscript()
                    } else {
                        self.task = nil
                        self.request = nil
                        self.onUpdate = nil
                        let failure = self.onFailure
                        self.onFailure = nil
                        failure?(error.localizedDescription)
                    }
                } else if result == nil {
                    self.completeFinalTranscript()
                }
            }
        }
    }

    func append(samples: [Int16]) throws {
        guard !samples.isEmpty, let request else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(EvenG1AudioFormat.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.int16ChannelData?.pointee else {
            throw TranscriberError.audioFormatUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        request.append(buffer)
    }

    func finish() async -> String {
        guard request != nil else { return latestTranscript }
        request?.endAudio()
        return await withCheckedContinuation { continuation in
            finalContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.completeFinalTranscript()
            }
        }
    }

    func cancel() {
        recognitionGeneration &+= 1
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        onUpdate = nil
        onFailure = nil
        completeFinalTranscript()
    }

    private func completeFinalTranscript() {
        guard let continuation = finalContinuation else { return }
        finalContinuation = nil
        task = nil
        request = nil
        onUpdate = nil
        onFailure = nil
        continuation.resume(returning: latestTranscript)
    }
}

enum EvenG1AudioFormat {
    static let sampleRate = 16_000
}
