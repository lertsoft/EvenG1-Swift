import Combine
import Foundation
import EvenG1Core

@MainActor
final class GlassesVoiceCoordinator: ObservableObject {
    enum Mode: Equatable {
        case idle
        case listeningForAssistant
        case thinking
        case translating
        case failed(String)
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var response = ""
    @Published private(set) var finalizedTranslationSource: String?
    @Published private(set) var translationRevision = 0
    @Published private(set) var isTranslationActive = false
    @Published private(set) var translationStopRevision = 0
    @Published var speechLocaleIdentifier = Locale.current.identifier

    private weak var bluetoothManager: G1BluetoothManager?
    private let transcriber = AppleSpeechTranscriber()
    private let decoder = try? G1LC3Decoder()
    private let decodeQueue = DispatchQueue(label: "com.eveng1.voice.decode", qos: .userInitiated)
    private var packetCancellable: AnyCancellable?
    private var translationRunning = false
    private var resumeTranslationAfterAssistant = false
    private var isAssistantButtonHeld = false
    private var isAssistantCaptureStarting = false
    private var isTranslationDisplayPrepared = false

    var assistantAvailability: AppleAssistantAvailability {
        AppleIntelligenceAssistant.availability()
    }

    func bind(to manager: G1BluetoothManager) {
        guard bluetoothManager !== manager else { return }
        bluetoothManager = manager
        packetCancellable?.cancel()
        packetCancellable = manager.microphonePackets.sink { [weak self] packet in
            self?.decode(packet.payload)
        }
    }

    func handleGlassesEvent(_ event: G1Event) async -> Bool {
        switch event {
        case .pressAndHold:
            isAssistantButtonHeld = true
            await beginAssistantCapture()
            return true
        case .pressAndRelease:
            isAssistantButtonHeld = false
            if !isAssistantCaptureStarting {
                await finishAssistantCapture()
            }
            return true
        default:
            return false
        }
    }

    @discardableResult
    func startTranslation(preferredMicrophoneSide: GlassesSide = .right) async -> Bool {
        guard mode != .listeningForAssistant, mode != .thinking else { return false }
        translationRunning = true
        bluetoothManager?.setCustomDisplaySurfaceClaimed(true)
        transcript = ""
        response = ""

        if isTranslationDisplayPrepared {
            isTranslationDisplayPrepared = false
        } else {
            _ = await bluetoothManager?.clearDisplayAndWait()
        }
        do {
            try await startRecognition(for: .translating)
            let microphoneStarted = await bluetoothManager?
                .startMicrophone(preferredSide: preferredMicrophoneSide) == true
            guard microphoneStarted else {
                throw VoiceCoordinatorError.microphoneStartFailed
            }
            isTranslationActive = true
            response = "Listening…"
            bluetoothManager?.sendText(G1TextSendRequest(text: response, mode: .text))
            return true
        } catch {
            translationRunning = false
            mode = .failed(error.localizedDescription)
            isTranslationActive = false
            bluetoothManager?.setCustomDisplaySurfaceClaimed(false)
            transcriber.cancel()
            _ = await bluetoothManager?.stopMicrophone()
            decoder?.discardPartialFrame()
            return false
        }
    }

    func stopTranslation() async {
        translationRunning = false
        isTranslationDisplayPrepared = false
        mode = .idle
        isTranslationActive = false
        translationStopRevision &+= 1
        transcriber.cancel()
        _ = await bluetoothManager?.stopMicrophone()
        decoder?.discardPartialFrame()
        _ = await bluetoothManager?.clearDisplayAndWait()
        transcript = ""
        response = ""
        finalizedTranslationSource = nil
        bluetoothManager?.setCustomDisplaySurfaceClaimed(false)
    }

    /// Claim the lens before TranslationSession downloads or prepares its
    /// languages, which can otherwise leave a stale bitmap visible for several
    /// seconds after the user enables captions.
    func prepareDisplayForTranslation(displayAlreadyCleared: Bool = false) async {
        if let bluetoothManager {
            bluetoothManager.setCustomDisplaySurfaceClaimed(true)
            _ = await bluetoothManager.configureTiltDashboard(
                G1TiltDashboardConfig(enabled: true, headUpMode: .off, appEventFallback: true)
            )
        }
        if !displayAlreadyCleared {
            _ = await bluetoothManager?.clearDisplayAndWait()
        }
        isTranslationDisplayPrepared = true
    }

    func publishTranslation(_ translatedText: String) {
        let trimmed = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        response = trimmed
        bluetoothManager?.sendText(G1TextSendRequest(text: trimmed, mode: .text))
    }

    func handleTranslationDisplayEvent(_ event: G1Event) -> Bool {
        guard isTranslationActive else { return false }
        switch event {
        case .headUp:
            let displayText = response.isEmpty ? "Listening…" : response
            bluetoothManager?.sendText(G1TextSendRequest(text: displayText, mode: .text))
            return true
        case .headDown:
            return true
        default:
            return false
        }
    }

    private func beginAssistantCapture() async {
        guard !isAssistantCaptureStarting,
              mode != .thinking,
              mode != .listeningForAssistant else { return }
        isAssistantCaptureStarting = true
        let shouldResumeTranslation = translationRunning
        resumeTranslationAfterAssistant = shouldResumeTranslation
        if shouldResumeTranslation {
            transcriber.cancel()
            translationRunning = false
        }
        transcript = ""
        response = ""
        do {
            try await startRecognition(for: .listeningForAssistant)
            guard await bluetoothManager?.startMicrophone() == true else {
                throw VoiceCoordinatorError.microphoneStartFailed
            }
            isAssistantCaptureStarting = false
            bluetoothManager?.sendText("Listening…")
            if !isAssistantButtonHeld {
                await finishAssistantCapture()
            }
        } catch {
            isAssistantCaptureStarting = false
            transcriber.cancel()
            _ = await bluetoothManager?.stopMicrophone()
            decoder?.discardPartialFrame()
            mode = .failed(error.localizedDescription)
            await resumeTranslationIfNeeded()
        }
    }

    private func finishAssistantCapture() async {
        guard mode == .listeningForAssistant else { return }
        _ = await bluetoothManager?.stopMicrophone()
        let finalText = await transcriber.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        decoder?.discardPartialFrame()
        guard !finalText.isEmpty else {
            mode = .failed("I didn't hear anything.")
            bluetoothManager?.sendText("I didn't hear anything.")
            await resumeTranslationIfNeeded()
            return
        }

        transcript = finalText
        mode = .thinking
        bluetoothManager?.sendText(G1TextSendRequest(text: "Thinking…", mode: .ai))
        do {
            let answer = try await AppleIntelligenceAssistant.answer(finalText)
            response = answer
            bluetoothManager?.sendText(G1TextSendRequest(text: answer, mode: .ai))
            mode = .idle
            await resumeTranslationIfNeeded()
        } catch {
            mode = .failed(error.localizedDescription)
            bluetoothManager?.sendText("Assistant unavailable: \(error.localizedDescription)")
            await resumeTranslationIfNeeded()
        }
    }

    private func startRecognition(for newMode: Mode) async throws {
        let locale = Locale(identifier: speechLocaleIdentifier)
        if newMode == .translating {
            finalizedTranslationSource = nil
        }
        try await transcriber.start(locale: locale) { [weak self] text, isFinal in
            guard let self else { return }
            self.transcript = text
            if newMode == .translating,
               !text.isEmpty,
               text != self.finalizedTranslationSource {
                self.finalizedTranslationSource = text
                self.translationRevision &+= 1
            }
            if newMode == .translating, isFinal, !text.isEmpty {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, self.translationRunning else { return }
                    try? await self.startRecognition(for: .translating)
                }
            }
        } onFailure: { [weak self] message in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleRecognitionFailure(message, recognitionMode: newMode)
            }
        }
        mode = newMode
    }

    private func handleRecognitionFailure(_ message: String, recognitionMode: Mode) async {
        guard mode == recognitionMode else { return }
        if recognitionMode == .translating {
            translationRunning = false
        }
        mode = .failed(message)
        if recognitionMode == .translating {
            isTranslationActive = false
            bluetoothManager?.setCustomDisplaySurfaceClaimed(false)
        }
        _ = await bluetoothManager?.stopMicrophone()
        decoder?.discardPartialFrame()
        if recognitionMode == .listeningForAssistant {
            await resumeTranslationIfNeeded()
        }
    }

    private func decode(_ payload: Data) {
        guard mode == .listeningForAssistant || mode == .translating, let decoder else { return }
        decodeQueue.async { [weak self] in
            do {
                let samples = try decoder.decode(payload)
                guard !samples.isEmpty else { return }
                Task { @MainActor [weak self] in
                    try? self?.transcriber.append(samples: samples)
                }
            } catch {
                Task { @MainActor [weak self] in
                    await self?.handleDecodeFailure()
                }
            }
        }
    }

    private func handleDecodeFailure() async {
        let wasTranslating = translationRunning
        translationRunning = false
        mode = .failed("Glasses audio decode failed.")
        if wasTranslating {
            isTranslationActive = false
            bluetoothManager?.setCustomDisplaySurfaceClaimed(false)
        }
        transcriber.cancel()
        _ = await bluetoothManager?.stopMicrophone()
        decoder?.discardPartialFrame()
        if !wasTranslating {
            await resumeTranslationIfNeeded()
        }
    }

    private func resumeTranslationIfNeeded() async {
        guard resumeTranslationAfterAssistant else { return }
        resumeTranslationAfterAssistant = false
        await startTranslation()
    }
}

private enum VoiceCoordinatorError: LocalizedError {
    case microphoneStartFailed

    var errorDescription: String? {
        "The glasses microphone could not be started."
    }
}
