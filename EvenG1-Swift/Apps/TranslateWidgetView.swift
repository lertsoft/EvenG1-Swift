import SwiftUI
import Translation
import EvenG1Core

@available(iOS 18.0, *)
extension TranslationSession: @retroactive @unchecked Sendable {}

@available(iOS 18.0, *)
struct TranslateWidgetView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var voiceCoordinator: GlassesVoiceCoordinator
    @EnvironmentObject private var appActionRouter: AppActionRouter

    @AppStorage("translation.sourceLanguage") private var sourceIdentifier = "en"
    @AppStorage("translation.targetLanguage") private var targetIdentifier = "es"
    @AppStorage(TranslationPreferences.sideButtonEnabledKey)
    private var sideButtonActivationEnabled = false
    @AppStorage(TranslationPreferences.sideButtonDurationKey)
    private var sideButtonDurationSeconds =
        TranslationPreferences.defaultSideButtonDurationSeconds
    @State private var configuration: TranslationSession.Configuration?
    @State private var configuredSourceIdentifier: String?
    @State private var configuredTargetIdentifier: String?
    @State private var sessionBox: TranslationSessionBox?
    @State private var translatedText = ""
    @State private var statusText = "Choose languages, then start live captions."
    @State private var isRunning = false
    @State private var sideButtonAutoStopAt: Date?
    @State private var preferredMicrophoneSide: GlassesSide = .right
    @State private var pendingExternalStartRevision: Int?

    private let languages: [TranslationLanguageChoice] = [
        .init(identifier: "en", name: "English"),
        .init(identifier: "es", name: "Spanish"),
        .init(identifier: "fr", name: "French"),
        .init(identifier: "de", name: "German"),
        .init(identifier: "it", name: "Italian"),
        .init(identifier: "pt", name: "Portuguese"),
        .init(identifier: "ja", name: "Japanese"),
        .init(identifier: "ko", name: "Korean"),
        .init(identifier: "zh-Hans", name: "Chinese (Simplified)")
    ]
    private let sideButtonDurations: [TranslationDurationChoice] = [
        .init(seconds: 60, name: "1 minute"),
        .init(seconds: 300, name: "5 minutes"),
        .init(seconds: 900, name: "15 minutes"),
        .init(seconds: 1_800, name: "30 minutes"),
        .init(seconds: 0, name: "Until stopped")
    ]

    var body: some View {
        List {
            Section("Languages") {
                Picker("Spoken language", selection: $sourceIdentifier) {
                    ForEach(languages) { Text($0.name).tag($0.identifier) }
                }
                Picker("Display language", selection: $targetIdentifier) {
                    ForEach(languages) { Text($0.name).tag($0.identifier) }
                }
                Text("Speech and translation stay on this device. The selected languages require a one-time download before offline use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live captions") {
                LabeledContent("Status", value: statusText)
                    .accessibilityIdentifier("translation.status")
                if !voiceCoordinator.transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Heard").font(.caption).foregroundStyle(.secondary)
                        Text(voiceCoordinator.transcript)
                    }
                }
                if !translatedText.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("On your glasses").font(.caption).foregroundStyle(.secondary)
                        Text(translatedText).font(.headline)
                    }
                }

                Button(isRunning ? "Stop live captions" : "Start live captions") {
                    Task { await toggleTranslation() }
                }
                .disabled(
                    sourceIdentifier == targetIdentifier
                        || (!isRunning && bluetoothManager.connectionState != .fullyConnected)
                )
                .accessibilityIdentifier("translation.toggleButton")

            }

            Section("Glasses TouchBar") {
                Toggle("Control captions with double tap", isOn: $sideButtonActivationEnabled)
                Picker("Session length", selection: $sideButtonDurationSeconds) {
                    ForEach(sideButtonDurations) { choice in
                        Text(choice.name).tag(choice.seconds)
                    }
                }
                .disabled(!sideButtonActivationEnabled)

                Text("Double-tap either TouchBar to start or stop captions. This avoids the stock Even AI long-press action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice assistant") {
                Text("Outside Live Translate, hold the left-arm TouchBar, speak, and release to use the voice assistant.")
                Text(voiceCoordinator.assistantAvailability.message)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Translate")
        .translationTask(configuration) { newSession in
            let box = TranslationSessionBox(newSession)
            sessionBox = box
            do {
                statusText = "Preparing on-device languages…"
                try await box.prepare()
                try await verifyOfflineTranslationAssets()
                guard isRunning, sessionBox === box else { return }
                statusText = "Offline languages ready. Starting the glasses microphone…"
                if await voiceCoordinator.startTranslation(
                    preferredMicrophoneSide: preferredMicrophoneSide
                ) {
                    statusText = "Listening through the glasses"
                    completeExternalStartRequest()
                } else {
                    isRunning = false
                    sessionBox = nil
                    completeExternalStartRequest()
                    if case .failed(let message) = voiceCoordinator.mode {
                        statusText = message
                    } else {
                        statusText = "Translation could not be started."
                    }
                }
            } catch {
                guard sessionBox === box else { return }
                statusText = error.localizedDescription
                isRunning = false
                sessionBox = nil
                completeExternalStartRequest()
                await voiceCoordinator.stopTranslation()
            }
        }
        .task(id: voiceCoordinator.translationRevision) {
            guard voiceCoordinator.translationRevision > 0,
                  let source = voiceCoordinator.finalizedTranslationSource else { return }
            let revision = voiceCoordinator.translationRevision
            await translate(source, revision: revision)
        }
        .onDisappear {
            sideButtonAutoStopAt = nil
            if isRunning {
                Task { await voiceCoordinator.stopTranslation() }
            }
        }
        .onChange(of: voiceCoordinator.isTranslationActive) { wasActive, isActive in
            guard wasActive, !isActive, isRunning else { return }
            isRunning = false
            sessionBox = nil
            sideButtonAutoStopAt = nil
            translatedText = ""
            if case .failed(let message) = voiceCoordinator.mode {
                statusText = message
            } else {
                statusText = "Stopped"
            }
        }
        .onChange(of: voiceCoordinator.translationStopRevision) { _, _ in
            guard isRunning else { return }
            isRunning = false
            sessionBox = nil
            sideButtonAutoStopAt = nil
            translatedText = ""
            statusText = "Stopped"
        }
        .task(id: appActionRouter.translationStartRevision) {
            guard let request = appActionRouter.consumeTranslationStartRequest() else {
                return
            }
            guard !isRunning else {
                appActionRouter.completeTranslationStartRequest(revision: request.revision)
                return
            }
            pendingExternalStartRevision = request.revision
            let accepted = await toggleTranslation(
                preferredMicrophoneSide: request.startedFromSideButton ? .left : .right,
                displayAlreadyCleared: request.startedFromSideButton
            )
            guard accepted else {
                completeExternalStartRequest()
                return
            }
            if let seconds = request.autoStopSeconds {
                sideButtonAutoStopAt = Date().addingTimeInterval(TimeInterval(seconds))
            }
        }
        .task(id: sideButtonAutoStopAt) {
            guard let stopAt = sideButtonAutoStopAt else { return }
            let milliseconds = Int64(max(0, stopAt.timeIntervalSinceNow) * 1_000)
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard isRunning, sideButtonAutoStopAt == stopAt else { return }
            await stopTranslation(status: "Side-button live captions ended.")
        }
    }

    private func toggleTranslation(
        preferredMicrophoneSide: GlassesSide = .right,
        displayAlreadyCleared: Bool = false
    ) async -> Bool {
        if isRunning {
            await stopTranslation(status: "Stopped")
            return false
        }

        guard bluetoothManager.connectionState == .fullyConnected else {
            statusText = "Connect both glasses before starting live captions."
            return false
        }
        guard sourceIdentifier != targetIdentifier else {
            statusText = "Choose two different languages."
            return false
        }

        await voiceCoordinator.prepareDisplayForTranslation(
            displayAlreadyCleared: displayAlreadyCleared
        )
        isRunning = true
        translatedText = ""
        sessionBox = nil
        self.preferredMicrophoneSide = preferredMicrophoneSide
        voiceCoordinator.speechLocaleIdentifier = sourceIdentifier
        statusText = "Preparing languages…"
        triggerTranslationSession()
        return true
    }

    private func stopTranslation(status: String) async {
        isRunning = false
        sessionBox = nil
        sideButtonAutoStopAt = nil
        translatedText = ""
        await voiceCoordinator.stopTranslation()
        statusText = status
    }

    private func completeExternalStartRequest() {
        guard let revision = pendingExternalStartRevision else { return }
        pendingExternalStartRevision = nil
        appActionRouter.completeTranslationStartRequest(revision: revision)
    }

    private func triggerTranslationSession() {
        if configuration != nil,
           configuredSourceIdentifier == sourceIdentifier,
           configuredTargetIdentifier == targetIdentifier {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: sourceIdentifier),
                target: Locale.Language(identifier: targetIdentifier)
            )
            configuredSourceIdentifier = sourceIdentifier
            configuredTargetIdentifier = targetIdentifier
        }
    }

    private func verifyOfflineTranslationAssets() async throws {
        let source = Locale.Language(identifier: sourceIdentifier)
        let target = Locale.Language(identifier: targetIdentifier)
        let status = await LanguageAvailability().status(from: source, to: target)

        switch status {
        case .installed:
            return
        case .supported:
            throw OfflineTranslationError.assetsNotInstalled
        case .unsupported:
            throw OfflineTranslationError.unsupportedLanguagePair
        @unknown default:
            throw OfflineTranslationError.unknownAvailability
        }
    }

    private func translate(_ source: String, revision: Int) async {
        guard isRunning, let sessionBox else { return }
        do {
            let targetText = try await sessionBox.translate(source)
            guard revision == voiceCoordinator.translationRevision else {
                return
            }
            translatedText = targetText
            voiceCoordinator.publishTranslation(targetText)
            statusText = "Listening through the glasses"
        } catch {
            guard !Task.isCancelled else { return }
            statusText = error.localizedDescription
        }
    }
}

private struct TranslationLanguageChoice: Identifiable {
    let identifier: String
    let name: String
    var id: String { identifier }
}

private struct TranslationDurationChoice: Identifiable {
    let seconds: Int
    let name: String
    var id: Int { seconds }
}

private enum OfflineTranslationError: LocalizedError {
    case assetsNotInstalled
    case unsupportedLanguagePair
    case unknownAvailability

    var errorDescription: String? {
        switch self {
        case .assetsNotInstalled:
            return "The offline language download is not finished. Connect once, complete the download, then try again."
        case .unsupportedLanguagePair:
            return "Apple Translation does not support this language pair."
        case .unknownAvailability:
            return "Offline translation availability could not be confirmed."
        }
    }
}

/// TranslationSession predates Swift 6's Sendable annotations. Calls are
/// serialized by the view task and the framework owns its internal safety.
@available(iOS 18.0, *)
private final class TranslationSessionBox: @unchecked Sendable {
    private let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func prepare() async throws {
        try await session.prepareTranslation()
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}
