import Foundation
import SwiftProtobuf
import XCTest
@testable import EvenG1Core

final class MTARealtimeFeedClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testFetchSubwayServiceAlertsFeedUsesAPIKeyAndAlertsPath() async throws {
        let expectation = XCTestExpectation(description: "request captured")
        var capturedRequest: URLRequest?

        URLProtocolStub.handler = { request in
            capturedRequest = request
            expectation.fulfill()

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Self.emptyFeedData())
        }

        let client = MTARealtimeFeedClient(session: makeSession(), feedPaths: ["nyct%2Fgtfs"])
        _ = try await client.fetchSubwayServiceAlertsFeed(apiKey: "test-key")

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/x-protobuf")
        XCTAssertEqual(capturedRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(capturedRequest?.timeoutInterval, 15)
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("camsys%2Fsubway-alerts") == true)
    }

    func testFetchWithoutAPIKeyStillRequestsFeedAndOmitsCredentialHeader() async throws {
        let expectation = XCTestExpectation(description: "anonymous request captured")
        var capturedRequest: URLRequest?

        URLProtocolStub.handler = { request in
            capturedRequest = request
            expectation.fulfill()

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Self.emptyFeedData())
        }

        let client = MTARealtimeFeedClient(session: makeSession(), feedPaths: ["nyct%2Fgtfs"])
        let feeds = try await client.fetchSubwayRealtimeFeeds()

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(feeds.count, 1)
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/x-protobuf")
    }

    func testFetchSubwayRealtimeFeedsHitsAllConfiguredPaths() async throws {
        let expectedPaths = ["nyct%2Fgtfs", "nyct%2Fgtfs-ace"]
        var capturedURLs: [String] = []
        let lock = NSLock()

        URLProtocolStub.handler = { request in
            lock.lock()
            capturedURLs.append(request.url?.absoluteString ?? "")
            lock.unlock()

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Self.emptyFeedData())
        }

        let client = MTARealtimeFeedClient(session: makeSession(), feedPaths: expectedPaths)
        _ = try await client.fetchSubwayRealtimeFeeds(apiKey: "test-key")

        let expectedURLs = Set(expectedPaths.map { "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/\($0)" })
        XCTAssertEqual(Set(capturedURLs), expectedURLs)

        _ = try await client.fetchAllFeeds(apiKey: "test-key")
    }

    func testFetchSubwayRealtimeFeedsReturnsPartialResultsWhenOneFeedFails() async throws {
        let expectedPaths = ["nyct%2Fgtfs", "nyct%2Fgtfs-7"]

        URLProtocolStub.handler = { request in
            if request.url?.absoluteString.contains("gtfs-7") == true {
                throw URLError(.timedOut)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Self.emptyFeedData())
        }

        let client = MTARealtimeFeedClient(session: makeSession(), feedPaths: expectedPaths)
        let feeds = try await client.fetchSubwayRealtimeFeeds(apiKey: "test-key")

        XCTAssertEqual(feeds.count, 1)
    }

    func testFetchSubwayRealtimeFeedsThrowsWhenEveryFeedFails() async {
        URLProtocolStub.handler = { _ in
            throw URLError(.timedOut)
        }

        let client = MTARealtimeFeedClient(
            session: makeSession(),
            feedPaths: ["nyct%2Fgtfs", "nyct%2Fgtfs-7"]
        )

        do {
            _ = try await client.fetchSubwayRealtimeFeeds(apiKey: "test-key")
            XCTFail("Expected all-feed failure to throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotLoadFromNetwork)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultSubwayRealtimeFeedPathsRemainStable() {
        XCTAssertEqual(MTARealtimeFeedClient.defaultFeedPaths, [
            "nyct%2Fgtfs",
            "nyct%2Fgtfs-ace",
            "nyct%2Fgtfs-bdfm",
            "nyct%2Fgtfs-g",
            "nyct%2Fgtfs-jz",
            "nyct%2Fgtfs-nqrw",
            "nyct%2Fgtfs-l",
            "nyct%2Fgtfs-7",
            "nyct%2Fgtfs-si"
        ])
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    private static func emptyFeedData() throws -> Data {
        var feed = GTFSProto_FeedMessage()
        feed.entity = []
        return try feed.serializedData()
    }
}

private final class URLProtocolStub: URLProtocol {
    private final class HandlerStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedHandler
            }
            set {
                lock.lock()
                storedHandler = newValue
                lock.unlock()
            }
        }
    }

    private static let handlerStorage = HandlerStorage()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerStorage.handler }
        set { handlerStorage.handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
