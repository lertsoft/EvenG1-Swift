import Foundation

#if canImport(DatadogRUM)
import DatadogRUM

public extension URLSession {
    /// Performs `data(for:)` and reports the request to Datadog RUM as a resource on
    /// the active view.
    ///
    /// Resources are reported manually rather than through
    /// `URLSessionInstrumentation`, which recognizes a request by the class of its
    /// session delegate. These clients call the async `data(for:)` on a delegate-less
    /// session, so automatic instrumentation has nothing to match and would risk
    /// starting resources it never stops. Starting and stopping them here is exact,
    /// and distributed tracing is moot against a third-party API.
    func dataReportingRUMResource(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard DatadogTelemetryService.shared.isInitialized else {
            return try await self.data(for: request)
        }

        // The monitor is re-fetched after the suspension rather than held across it,
        // so no non-Sendable value spans the await.
        let resourceKey = UUID().uuidString
        RUMMonitor.shared().startResource(resourceKey: resourceKey, request: request, attributes: [:])

        do {
            let (data, response) = try await self.data(for: request)
            RUMMonitor.shared().stopResource(
                resourceKey: resourceKey,
                response: response,
                size: Int64(data.count),
                attributes: [:]
            )
            return (data, response)
        } catch {
            RUMMonitor.shared().stopResourceWithError(
                resourceKey: resourceKey,
                error: error,
                response: nil,
                attributes: [:]
            )
            throw error
        }
    }
}
#else
public extension URLSession {
    /// Host-platform fallback used when Datadog's UIKit-based RUM product is
    /// unavailable.
    func dataReportingRUMResource(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}
#endif
