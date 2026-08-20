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
    @State private var configuration: TranslationSession.Configuration?
    @State private var sessionBox: TranslationSessionBox?
    @State private var translatedText = ""
    @State private var statusText = "Choose languages, then start live captions."
    @State private var isRunning = false

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

    var body: some View {
        List {
            Section("Languages") {
                Picker("Spoken language", selection: $sourceIdentifier) {
                    ForEach(languages) { Text($0.name).tag($0.identifier) }
                }
                Picker("Display language", selection: $targetIdentifier) {
                    ForEach(languages) { Text($0.name).tag($0.identifier) }
                }
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

                Text("You can also press and hold the left glasses TouchBar to start live captions while this screen is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice assistant") {
                Text("Outside Live Translate, hold the glasses side button, speak, and release to use the voice assistant.")
                Text(voiceCoordinator.assistantAvailability.message)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Translate")
        .onAppear {
            appActionRouter.setTranslationForeground(true)
        }
        .translationTask(configuration) { newSession in
            let box = TranslationSessionBox(newSession)
            sessionBox = box
            do {
                statusText = "Preparing on-device languages…"
                try await box.prepare()
                guard isRunning, sessionBox === box else { return }
                statusText = "Starting the glasses microphone…"
                if await voiceCoordinator.startTranslation() {
                    statusText = "Listening through the glasses"
                } else {
                    isRunning = false
                    configuration = nil
                    sessionBox = nil
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
                configuration = nil
                sessionBox = nil
                await voiceCoordinator.stopTranslation()
            }
        }
        .onChange(of: voiceCoordinator.translationRevision) { _, _ in
            guard let source = voiceCoordinator.finalizedTranslationSource else { return }
            Task { await translate(source) }
        }
        .onDisappear {
            appActionRouter.setTranslationForeground(false)
            if isRunning {
                Task { await voiceCoordinator.stopTranslation() }
            }
        }
        .onChange(of: voiceCoordinator.isTranslationActive) { wasActive, isActive in
            guard wasActive, !isActive, isRunning else { return }
            isRunning = false
            configuration = nil
            sessionBox = nil
            if case .failed(let message) = voiceCoordinator.mode {
                statusText = message
            } else {
                statusText = "Stopped"
            }
        }
        .onChange(of: voiceCoordinator.translationStopRevision) { _, _ in
            guard isRunning else { return }
            isRunning = false
            configuration = nil
            sessionBox = nil
            statusText = "Stopped"
        }
        .task(id: appActionRouter.translationStartRevision) {
            guard appActionRouter.translationStartRevision > 0, !isRunning else { return }
            await toggleTranslation()
        }
    }

    private func toggleTranslation() async {
        if isRunning {
            isRunning = false
            configuration = nil
            sessionBox = nil
            await voiceCoordinator.stopTranslation()
            statusText = "Stopped"
            return
        }

        guard bluetoothManager.connectionState == .fullyConnected else {
            statusText = "Connect both glasses before starting live captions."
            return
        }
        guard sourceIdentifier != targetIdentifier else {
            statusText = "Choose two different languages."
            return
        }

        await voiceCoordinator.prepareDisplayForTranslation()
        isRunning = true
        translatedText = ""
        sessionBox = nil
        voiceCoordinator.speechLocaleIdentifier = sourceIdentifier
        statusText = "Preparing languages…"
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceIdentifier),
            target: Locale.Language(identifier: targetIdentifier)
        )
    }

    private func translate(_ source: String) async {
        guard isRunning, let sessionBox else { return }
        do {
            let targetText = try await sessionBox.translate(source)
            translatedText = targetText
            voiceCoordinator.publishTranslation(targetText)
            statusText = "Listening through the glasses"
        } catch {
            statusText = error.localizedDescription
        }
    }
}

private struct TranslationLanguageChoice: Identifiable {
    let identifier: String
    let name: String
    var id: String { identifier }
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
