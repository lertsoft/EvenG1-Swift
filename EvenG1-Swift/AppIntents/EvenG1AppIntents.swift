import AppIntents
import Foundation

enum PendingAppActionKind: String, Codable {
    case startFavoriteNavigation
    case nextTrain
    case startTranslation
    case stopTranslation
    case sendNote
}

struct PendingAppAction: Codable {
    let kind: PendingAppActionKind
    let value: String?
}

enum PendingAppActionStore {
    private static let key = "EvenG1.pendingAppAction"

    static func enqueue(_ action: PendingAppAction) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func consume() -> PendingAppAction? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return try? JSONDecoder().decode(PendingAppAction.self, from: data)
    }
}

struct StartFavoriteNavigationIntent: AppIntent {
    static let title: LocalizedStringResource = "Navigate with EvenG1"
    static let description = IntentDescription("Start glasses navigation to a saved EvenG1 destination.")
    static let openAppWhenRun = true

    @Parameter(title: "Favorite") var favorite: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            PendingAppActionStore.enqueue(.init(kind: .startFavoriteNavigation, value: favorite))
        }
        return .result(dialog: "Opening EvenG1 to route to \(favorite).")
    }
}

struct NextSavedStationTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Train on EvenG1"
    static let description = IntentDescription("Refresh the next trains for the station saved in EvenG1.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            PendingAppActionStore.enqueue(.init(kind: .nextTrain, value: nil))
        }
        return .result(dialog: "Refreshing your saved station in EvenG1.")
    }
}

struct StartGlassesTranslationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start EvenG1 Translation"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            PendingAppActionStore.enqueue(.init(kind: .startTranslation, value: nil))
        }
        return .result(dialog: "Starting translated captions in EvenG1.")
    }
}

struct StopGlassesTranslationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop EvenG1 Translation"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            PendingAppActionStore.enqueue(.init(kind: .stopTranslation, value: nil))
        }
        return .result(dialog: "Stopping translated captions.")
    }
}

struct SendGlassesNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Note to EvenG1"
    static let openAppWhenRun = true

    @Parameter(title: "Note") var note: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            PendingAppActionStore.enqueue(.init(kind: .sendNote, value: note))
        }
        return .result(dialog: "Sending the note to your glasses.")
    }
}

struct EvenG1Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFavoriteNavigationIntent(),
            phrases: ["Navigate with \(.applicationName)"],
            shortTitle: "Navigate",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: NextSavedStationTrainIntent(),
            phrases: ["Show my next train with \(.applicationName)"],
            shortTitle: "Next Train",
            systemImageName: "tram.fill"
        )
        AppShortcut(
            intent: StartGlassesTranslationIntent(),
            phrases: ["Start translation with \(.applicationName)"],
            shortTitle: "Start Translation",
            systemImageName: "translate"
        )
        AppShortcut(
            intent: SendGlassesNoteIntent(),
            phrases: ["Send a note with \(.applicationName)"],
            shortTitle: "Send Note",
            systemImageName: "note.text"
        )
    }
}
