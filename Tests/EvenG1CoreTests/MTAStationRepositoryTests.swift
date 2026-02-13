import Foundation
import XCTest
@testable import EvenG1Core

final class MTAStationRepositoryTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testDecodesStationPayload() async throws {
        let payload = """
        [
          {"gtfs_stop_id":"R14N","stop_name":"14 St - Union Sq","gtfs_latitude":"40.734673","gtfs_longitude":"-73.989951"},
          {"gtfs_stop_id":"R14S","stop_name":"14 St - Union Sq","gtfs_latitude":"40.734673","gtfs_longitude":"-73.989951"}
        ]
        """.data(using: .utf8)!

        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, payload)
        }

        let repository = makeRepository(cacheTTL: 3600)
        let stations = try await repository.loadStations(now: Date(timeIntervalSince1970: 1_735_689_600))

        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.gtfsStopID, "R14")
        XCTAssertEqual(stations.first?.stopName, "14 St - Union Sq")
    }

    func testUsesDiskCacheWhenNetworkUnavailableWithinTTL() async throws {
        let payload = """
        [{"gtfs_stop_id":"A12","stop_name":"Canal St","gtfs_latitude":"40.720824","gtfs_longitude":"-74.005229"}]
        """.data(using: .utf8)!

        let cacheDirectory = temporaryDirectory()

        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, payload)
        }

        let firstRepository = makeRepository(cacheDirectory: cacheDirectory, cacheTTL: 3600)
        let first = try await firstRepository.loadStations(now: Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertEqual(first.first?.gtfsStopID, "A12")

        URLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let secondRepository = makeRepository(cacheDirectory: cacheDirectory, cacheTTL: 3600)
        let second = try await secondRepository.loadStations(now: Date(timeIntervalSince1970: 1_735_689_650))

        XCTAssertEqual(second.first?.gtfsStopID, "A12")
    }

    func testRefreshesStaleCache() async throws {
        let firstPayload = """
        [{"gtfs_stop_id":"A12","stop_name":"Old","gtfs_latitude":"40.70","gtfs_longitude":"-74.00"}]
        """.data(using: .utf8)!

        let secondPayload = """
        [{"gtfs_stop_id":"B34","stop_name":"New","gtfs_latitude":"40.71","gtfs_longitude":"-74.01"}]
        """.data(using: .utf8)!

        let cacheDirectory = temporaryDirectory()
        var responseIndex = 0

        URLProtocolStub.handler = { request in
            defer { responseIndex += 1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseIndex == 0 ? firstPayload : secondPayload)
        }

        let repository = makeRepository(cacheDirectory: cacheDirectory, cacheTTL: 1)

        let first = try await repository.loadStations(now: Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertEqual(first.first?.gtfsStopID, "A12")

        let second = try await repository.loadStations(now: Date(timeIntervalSince1970: 1_735_689_603))
        XCTAssertEqual(second.first?.gtfsStopID, "B34")
    }

    private func makeRepository(cacheDirectory: URL? = nil, cacheTTL: TimeInterval) -> MTAStationRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: config)

        return MTAStationRepository(
            session: session,
            endpoint: URL(string: "https://example.com/stations.json")!,
            cacheDirectoryURL: cacheDirectory,
            cacheTTL: cacheTTL
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
