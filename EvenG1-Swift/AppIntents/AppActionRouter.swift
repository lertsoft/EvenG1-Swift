import Combine
import Foundation

@MainActor
final class AppActionRouter: ObservableObject {
    @Published private(set) var favoriteNavigationRequest: String?
    @Published private(set) var favoriteNavigationRevision = 0
    @Published private(set) var translationStartRevision = 0
    @Published private(set) var isTranslationForeground = false

    func requestFavoriteNavigation(named name: String) {
        favoriteNavigationRequest = name
        favoriteNavigationRevision &+= 1
    }

    func requestTranslationStart() {
        translationStartRevision &+= 1
    }

    func setTranslationForeground(_ isForeground: Bool) {
        isTranslationForeground = isForeground
    }
}
