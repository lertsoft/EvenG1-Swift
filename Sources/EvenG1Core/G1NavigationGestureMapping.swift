import Foundation

public enum G1NavigationGestureAction: Sendable, Equatable {
    case repeatCurrentInstruction
    case announceStatus
    case previewNextStep
    case previewPreviousStep
    case recenterToLiveStep
    case endNavigation
    case toggleMute
    case showOverlay
    case hideOverlay
}

public struct G1NavigationGestureMapper {
    public init() {}

    public static func action(for event: G1Event,
                              isNavigationActive: Bool) -> G1NavigationGestureAction? {
        guard isNavigationActive else {
            return nil
        }

        switch event {
        case .doubleTap:
            return .repeatCurrentInstruction
        case .singleTap:
            return .announceStatus
        case .swipeForward:
            return .previewNextStep
        case .swipeBackward:
            return .previewPreviousStep
        case .tripleTap:
            return .recenterToLiveStep
        case .pressAndHold:
            return .endNavigation
        case .pressAndRelease:
            return .toggleMute
        case .headUp:
            return .showOverlay
        case .headDown:
            return .hideOverlay
        default:
            return nil
        }
    }
}
