import Combine
import Foundation

enum TranslationPreferences {
    static let sideButtonEnabledKey = "translation.sideButtonActivationEnabled"
    static let sideButtonDurationKey = "translation.sideButtonDurationSeconds"
    static let defaultSideButtonDurationSeconds = 300
}

struct TranslationStartRequest {
    let revision: Int
    let autoStopSeconds: Int?
    let startedFromSideButton: Bool
}

@MainActor
final class AppActionRouter: ObservableObject {
    @Published private(set) var favoriteNavigationRequest: String?
    @Published private(set) var favoriteNavigationRevision = 0
    @Published private(set) var translationStartRevision = 0
    @Published private(set) var translationStartCompletionRevision = 0
    @Published private(set) var translationAutoStopSeconds: Int?
    @Published private(set) var translationStartedFromSideButton = false
    private var consumedTranslationStartRevision = 0

    func requestFavoriteNavigation(named name: String) {
        favoriteNavigationRequest = name
        favoriteNavigationRevision &+= 1
    }

    func requestTranslationStart(
        autoStopAfterSeconds: Int? = nil,
        fromSideButton: Bool = false
    ) {
        translationAutoStopSeconds = autoStopAfterSeconds
        translationStartedFromSideButton = fromSideButton
        translationStartRevision &+= 1
    }

    func consumeTranslationStartRequest() -> TranslationStartRequest? {
        guard translationStartRevision != consumedTranslationStartRevision else {
            return nil
        }
        consumedTranslationStartRevision = translationStartRevision
        return TranslationStartRequest(
            revision: translationStartRevision,
            autoStopSeconds: translationAutoStopSeconds,
            startedFromSideButton: translationStartedFromSideButton
        )
    }

    func completeTranslationStartRequest(revision: Int) {
        guard revision == translationStartRevision else { return }
        translationStartCompletionRevision = revision
    }

}
