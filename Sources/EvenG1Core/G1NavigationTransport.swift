import Foundation

public struct G1NavigationTransportResult: Sendable, Equatable {
    public let deliveryMode: G1NavigationTransportMode
    public let nativeAcked: Bool
    public let downgradedToText: Bool

    public init(deliveryMode: G1NavigationTransportMode, nativeAcked: Bool, downgradedToText: Bool) {
        self.deliveryMode = deliveryMode
        self.nativeAcked = nativeAcked
        self.downgradedToText = downgradedToText
    }
}

public struct G1NavigationTransport: Sendable {
    public var failureThreshold: Int
    public private(set) var transportMode: G1NavigationTransportMode
    public private(set) var consecutiveNativeFailures: Int

    public init(failureThreshold: Int = 3,
                transportMode: G1NavigationTransportMode = .nativePackets,
                consecutiveNativeFailures: Int = 0) {
        self.failureThreshold = max(1, failureThreshold)
        self.transportMode = transportMode
        self.consecutiveNativeFailures = max(0, consecutiveNativeFailures)
    }

    public mutating func reset(transportMode: G1NavigationTransportMode = .nativePackets) {
        self.transportMode = transportMode
        self.consecutiveNativeFailures = 0
    }

    public mutating func forceTextFallback() {
        transportMode = .textFallback
    }

    @discardableResult
    @MainActor
    public mutating func performNativePreferred(nativeSend: @MainActor () async -> Bool,
                                                fallbackSend: @MainActor () async -> Void) async -> G1NavigationTransportResult {
        if transportMode == .textFallback {
            await fallbackSend()
            return G1NavigationTransportResult(deliveryMode: .textFallback, nativeAcked: false, downgradedToText: false)
        }

        let acked = await nativeSend()
        if acked {
            consecutiveNativeFailures = 0
            return G1NavigationTransportResult(deliveryMode: .nativePackets, nativeAcked: true, downgradedToText: false)
        }

        consecutiveNativeFailures += 1
        let downgraded = consecutiveNativeFailures >= failureThreshold
        if downgraded {
            transportMode = .textFallback
        }

        await fallbackSend()
        return G1NavigationTransportResult(deliveryMode: .textFallback, nativeAcked: false, downgradedToText: downgraded)
    }

    public mutating func registerNativeSuccess() {
        consecutiveNativeFailures = 0
        if transportMode == .textFallback {
            transportMode = .nativePackets
        }
    }
}
