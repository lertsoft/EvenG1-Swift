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
        case .swipeForward, .swipeBackward:
            // The right temple reports swipes the wearer never made, always as
            // perfectly alternating forward/backward pairs (19 pairs in one
            // 3.5-minute session with no touch input). Acting on them replaced
            // the live map with step previews and forced a bitmap upload every
            // couple of seconds, so navigation ignores them and step previews
            // stay on the phone.
            return nil
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
