import AudioMarker
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tagger

final class CoverArtArchiveClientTests: XCTestCase {
    private let releaseID = "f4cf6b7b-5d14-4f30-8a83-50a70591198f"

    func testFetchesValidatedJPEGAndPNGFromExactRelease() async throws {
        for format in [UTType.jpeg, .png] {
            let data = try imageData(format: format)
            let http = CoverArtHTTPStub(responses: [.success(response(data))])
            let client = CoverArtArchiveClient(httpClient: http, userAgent: "Tagger/Test")

            let artwork = try await client.frontCover(forReleaseID: releaseID.uppercased())

            XCTAssertEqual(artwork?.data, data, "Preserve the original validated image bytes")
            XCTAssertNoThrow(try Artwork(data: XCTUnwrap(artwork?.data)))
            let requests = await http.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "coverartarchive.org")
            XCTAssertEqual(request.url?.path, "/release/\(releaseID)/front-1200")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg, image/png")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Tagger/Test")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(artwork?.sourceURL, request.url)
        }
    }

    func testMissing1200ThumbnailFallsBackTo500ForTheSameRelease() async throws {
        let data = try imageData()
        let http = CoverArtHTTPStub(responses: [
            .success(response(status: 404)), .success(response(data)),
        ])
        let client = CoverArtArchiveClient(httpClient: http)

        let artwork = try await client.frontCover(forReleaseID: releaseID)

        XCTAssertEqual(artwork?.data, data)
        XCTAssertEqual(artwork?.sourceURL.path, "/release/\(releaseID)/front-500")
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/release/\(releaseID)/front-1200", "/release/\(releaseID)/front-500",
        ])
    }

    func testMissingFrontCoverReturnsNilWithoutTryingAnotherRelease() async throws {
        let http = CoverArtHTTPStub(responses: [
            .success(response(status: 404)), .success(response(status: 404)),
        ])
        let client = CoverArtArchiveClient(httpClient: http)

        let artwork = try await client.frontCover(forReleaseID: releaseID)

        XCTAssertNil(artwork)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasPrefix("/release/\(releaseID)/") == true })
    }

    func testRejectsInvalidReleaseIdentifiersBeforeMakingRequests() async {
        let http = CoverArtHTTPStub(responses: [])
        let client = CoverArtArchiveClient(httpClient: http)
        for invalidID in ["", "recording", "../../other", "\(releaseID)/front"] {
            do {
                _ = try await client.frontCover(forReleaseID: invalidID)
                XCTFail("Expected invalid release identifier to be rejected")
            } catch {
                XCTAssertEqual(error as? CoverArtArchiveError, .invalidReleaseID)
            }
        }
        let requests = await http.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPFailuresDoNotFallBackToAnotherThumbnail() async {
        for status in [301, 403, 429, 500, 503] {
            let http = CoverArtHTTPStub(responses: [.success(response(status: status))])
            let client = CoverArtArchiveClient(httpClient: http)
            do {
                _ = try await client.frontCover(forReleaseID: releaseID)
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? CoverArtArchiveError, .httpStatus(status))
            }
            let requests = await http.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testRejectsEmptyUnsupportedAndMalformedImages() async throws {
        let validPNG = try imageData()
        var corruptPNG = validPNG
        let imagePayload = try XCTUnwrap(corruptPNG.range(of: Data("IDAT".utf8)))
        corruptPNG[imagePayload.upperBound] ^= 0xff
        let cases: [(Data, CoverArtArchiveError)] = [
            (Data(), .unsupportedImage),
            (Data("<html>Server error</html>".utf8), .unsupportedImage),
            (try imageData(format: .gif), .unsupportedImage),
            (Data([0xff, 0xd8, 0xff, 0x00]), .invalidImage),
            (Data(validPNG.prefix(validPNG.count / 2)), .invalidImage),
            (corruptPNG, .invalidImage),
        ]
        for (index, item) in cases.enumerated() {
            let (data, expectedError) = item
            let http = CoverArtHTTPStub(responses: [.success(response(data))])
            let client = CoverArtArchiveClient(httpClient: http)
            do {
                _ = try await client.frontCover(forReleaseID: releaseID)
                XCTFail("Expected invalid image case \(index) to be rejected")
            } catch {
                XCTAssertEqual(error as? CoverArtArchiveError, expectedError)
            }
            let requests = await http.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testRejectsOversizedResponsesFromBothAdapterAndStub() async {
        let cases: [Result<HTTPResponse, Error>] = [
            .success(response(Data(repeating: 0, count: HTTPResponse.maximumDataSize + 1))),
            .failure(MusicBrainzError.responseTooLarge),
        ]
        for result in cases {
            let http = CoverArtHTTPStub(responses: [result])
            let client = CoverArtArchiveClient(httpClient: http)
            do {
                _ = try await client.frontCover(forReleaseID: releaseID)
                XCTFail("Expected oversized cover to be rejected")
            } catch {
                XCTAssertEqual(error as? CoverArtArchiveError, .responseTooLarge)
            }
        }
    }

    func testRejectsImagesOverDimensionAndPixelLimits() async throws {
        for (width, height) in [(4_097, 1), (3_000, 3_000)] {
            let data = try imageData(width: width, height: height)
            let http = CoverArtHTTPStub(responses: [.success(response(data))])
            let client = CoverArtArchiveClient(httpClient: http)
            do {
                _ = try await client.frontCover(forReleaseID: releaseID)
                XCTFail("Expected image dimensions to be rejected")
            } catch {
                XCTAssertEqual(error as? CoverArtArchiveError, .imageDimensionsTooLarge)
            }
        }
    }

    func testTransportCancellationPropagatesAsCancellation() async {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            let http = CoverArtHTTPStub(responses: [.failure(error)])
            let client = CoverArtArchiveClient(httpClient: http)
            do {
                _ = try await client.frontCover(forReleaseID: releaseID)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testRejectsLateSuccessAfterTaskCancellation() async throws {
        let http = CoverArtHTTPStub(
            responses: [.success(response(try imageData()))], cancelBeforeReturning: true
        )
        let client = CoverArtArchiveClient(httpClient: http)
        let releaseID = releaseID
        let task = Task { try await client.frontCover(forReleaseID: releaseID) }

        do {
            _ = try await task.value
            XCTFail("Expected cancelled task to discard downloaded artwork")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledTaskNeverStartsARequest() async {
        let http = CoverArtHTTPStub(responses: [])
        let client = CoverArtArchiveClient(httpClient: http)
        let releaseID = releaseID
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.frontCover(forReleaseID: releaseID)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await http.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func response(_ data: Data = Data(), status: Int = 200) -> HTTPResponse {
        HTTPResponse(data: data, statusCode: status, headers: [:])
    }

    private func imageData(format: UTType = .png, width: Int = 3, height: Int = 2) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor CoverArtHTTPStub: HTTPDataLoading {
    private var responses: [Result<HTTPResponse, Error>]
    private let cancelBeforeReturning: Bool
    private var requests: [URLRequest] = []

    init(responses: [Result<HTTPResponse, Error>], cancelBeforeReturning: Bool = false) {
        self.responses = responses
        self.cancelBeforeReturning = cancelBeforeReturning
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if cancelBeforeReturning { withUnsafeCurrentTask { $0?.cancel() } }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] { requests }
}
