import Foundation

/// Retains only the latest pending value while a drain loop is processing.
public struct G1LatestValueCoalescer<Value> {
    public private(set) var pending: Value?
    public private(set) var isDraining = false

    public init() {}

    public mutating func submit(_ value: Value) {
        pending = value
    }

    @discardableResult
    public mutating func beginDrain() -> Bool {
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    public mutating func nextPending() -> Value? {
        let value = pending
        pending = nil
        return value
    }

    public mutating func finishDrain() {
        isDraining = false
    }
}
