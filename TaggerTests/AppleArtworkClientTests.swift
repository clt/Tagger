import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tagger

final class AppleArtworkClientTests: XCTestCase {
    func testSearchEncodesLiteralPlusAndCanonicalUnicodeWithoutCredentials() async throws {
        let http = AppleArtworkHTTPStub(responses: [.success(searchResponse([]))])
        let client = AppleArtworkClient(httpClient: http, minimumInterval: .zero, userAgent: "Tagger/Test")

        _ = try await client.search(artist: "  Beyoncé + Guest  ".decomposedStringWithCanonicalMapping,
                                    album: " Café+ ".decomposedStringWithCanonicalMapping)

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "itunes.apple.com")
        XCTAssertEqual(request.url?.path, "/search")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Tagger/Test")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = try XCTUnwrap(components.percentEncodedQuery)
        XCTAssertFalse(query.contains("+"))
        let pairs = try query.split(separator: "&").map { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            return (String(pair[0]), try XCTUnwrap(String(pair[1])
                .replacingOccurrences(of: "+", with: " ").removingPercentEncoding))
        }
        let parameters = Dictionary(uniqueKeysWithValues: pairs)
        XCTAssertEqual(Array(try XCTUnwrap(parameters["term"]).utf8), Array("Beyoncé + Guest Café+".utf8))
        XCTAssertEqual(parameters["country"], "US")
        XCTAssertEqual(parameters["media"], "music")
        XCTAssertEqual(parameters["entity"], "album")
        XCTAssertEqual(parameters["limit"], "10")
    }

    func testPreservesEditionIdentityAndReportsActualDecodedDimensions() async throws {
        let data = try imageData()
        let http = AppleArtworkHTTPStub(responses: [
            .success(searchResponse([album(title: "Blue Lines (2012 Mix/Master)")])),
            .success(response(data)),
        ])
        let result = try await client(http).search(artist: "Massive Attack", album: "Blue Lines")

        let artwork = try XCTUnwrap(result.artworks.first)
        XCTAssertEqual(artwork.data, data)
        XCTAssertEqual(artwork.provider, .appleCatalog)
        XCTAssertEqual(artwork.title, "Blue Lines (2012 Mix/Master)")
        XCTAssertEqual(artwork.subtitle, "Massive Attack • 1991-04-08")
        XCTAssertEqual(artwork.sourceURL.absoluteString, "https://music.apple.com/us/album/blue-lines/1")
        XCTAssertEqual(artwork.pixelWidth, 7)
        XCTAssertEqual(artwork.pixelHeight, 5)
        XCTAssertFalse(artwork.isOriginal)
        XCTAssertNil(result.warningMessage)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.last?.url?.lastPathComponent, "3000x3000bb.jpg")
    }

    func testFiltersUnrelatedAlbumsDeduplicatesAndDownloadsAtMostThree() async throws {
        let records = [
            album(id: 8, artist: "Other Artist"), album(id: 9, title: "Mezzanine"),
            album(id: 10, title: "Blue Lines II"), album(id: 1), album(id: 1),
            album(id: 2, title: "Blue Lines (Deluxe)"), album(id: 3, title: "Blue Lines - The Remixes"),
            album(id: 4, title: "Blue Lines [Remastered]"),
        ]
        let image = response(try imageData())
        let http = AppleArtworkHTTPStub(responses: [.success(searchResponse(records))] + Array(repeating: .success(image), count: 3))

        let result = try await client(http).search(artist: "massive attack", album: "blue lines")

        XCTAssertEqual(result.artworks.map(\.sourceURL.lastPathComponent), ["1", "2", "3"])
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func testFallsBackToSuppliedURLWhenLargeVariantIsMissingInvalidOrTooLarge() async throws {
        let invalidDimensions = try imageData(width: 4_097, height: 1)
        let oversized = Data(repeating: 0, count: HTTPResponse.maximumDataSize + 1)
        let failures: [Result<HTTPResponse, Error>] = [
            .success(response(status: 404)), .success(response(Data("not an image".utf8))),
            .success(response(invalidDimensions)), .success(response(oversized)),
            .failure(MusicBrainzError.responseTooLarge),
        ]
        for failure in failures {
            let original = try imageData()
            let http = AppleArtworkHTTPStub(responses: [
                .success(searchResponse([album()])), failure, .success(response(original)),
            ])

            let result = try await client(http).search(artist: "Massive Attack", album: "Blue Lines")

            XCTAssertEqual(result.artworks.first?.data, original)
            XCTAssertNil(result.warningMessage)
            let requests = await http.recordedRequests()
            XCTAssertEqual(requests.suffix(2).map { $0.url?.lastPathComponent }, ["3000x3000bb.jpg", "100x100bb.jpg"])
        }
    }

    func testDoesNotRewriteUnrecognizedArtworkURLShape() async throws {
        let http = AppleArtworkHTTPStub(responses: [
            .success(searchResponse([album(imageURL: "https://is1-ssl.mzstatic.com/image/cover.png")])),
            .success(response(try imageData())),
        ])

        let result = try await client(http).search(artist: "Massive Attack", album: "Blue Lines")

        XCTAssertEqual(result.artworks.count, 1)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.url?.absoluteString, "https://is1-ssl.mzstatic.com/image/cover.png")
    }

    func testImageHTTPFailureIsNonfatalAndDoesNotFallBackOrHideOtherArtwork() async throws {
        let http = AppleArtworkHTTPStub(responses: [
            .success(searchResponse([album(id: 1), album(id: 2)])),
            .success(response(status: 503)), .success(response(try imageData())),
        ])

        let result = try await client(http).search(artist: "Massive Attack", album: "Blue Lines")

        XCTAssertEqual(result.artworks.map(\.sourceURL.lastPathComponent), ["2"])
        XCTAssertTrue(result.warningMessage?.contains("503") == true)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.url?.lastPathComponent == "3000x3000bb.jpg" })
    }

    func testRejectsUnsafeImageAndCollectionURLsBeforeImageRequests() async throws {
        let unsafeImages = [
            "http://is1-ssl.mzstatic.com/image/100x100bb.jpg",
            "https://mzstatic.com.evil.example/image/100x100bb.jpg",
            "https://user@is1-ssl.mzstatic.com/image/100x100bb.jpg",
            "https://is1-ssl.mzstatic.com:8443/image/100x100bb.jpg",
            "file:///tmp/cover.jpg",
        ]
        let records = unsafeImages.map { album(imageURL: $0) } + [
            album(collectionURL: "https://music.apple.com.evil.example/album/1"),
            album(collectionURL: "http://music.apple.com/us/album/1"),
        ]
        for record in records {
            let http = AppleArtworkHTTPStub(responses: [.success(searchResponse([record]))])

            let result = try await client(http).search(artist: "Massive Attack", album: "Blue Lines")

            XCTAssertTrue(result.artworks.isEmpty)
            XCTAssertNotNil(result.warningMessage)
            let requests = await http.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testBlankTermsNeverStartRequests() async {
        let http = AppleArtworkHTTPStub(responses: [])
        do {
            _ = try await client(http).search(artist: " ", album: "Blue Lines")
            XCTFail("Expected invalid search")
        } catch {
            XCTAssertEqual(error as? AppleArtworkError, .invalidSearch)
        }
        let requests = await http.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSearchRejectsMalformedHTTPAndOversizedResponses() async {
        let cases: [(Result<HTTPResponse, Error>, AppleArtworkError)] = [
            (.success(response(Data("{}".utf8))), .malformedResponse),
            (.success(response(status: 503)), .httpStatus(503)),
            (.success(response(Data(repeating: 0, count: HTTPResponse.maximumDataSize + 1))), .responseTooLarge),
            (.failure(MusicBrainzError.responseTooLarge), .responseTooLarge),
        ]
        for (response, expectedError) in cases {
            do {
                _ = try await client(AppleArtworkHTTPStub(responses: [response])).search(artist: "Massive Attack", album: "Blue Lines")
                XCTFail("Expected search failure")
            } catch {
                XCTAssertEqual(error as? AppleArtworkError, expectedError)
            }
        }
    }

    func testCancellationDuringImagesPropagatesInsteadOfWarningOrFallback() async throws {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            let http = AppleArtworkHTTPStub(responses: [.success(searchResponse([album()])), .failure(error)])
            do {
                _ = try await client(http).search(artist: "Massive Attack", album: "Blue Lines")
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let requests = await http.recordedRequests()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testCancelledTaskDiscardsLateImageResponse() async throws {
        let http = AppleArtworkHTTPStub(responses: [
            .success(searchResponse([album()])), .success(response(try imageData())),
        ], cancelOnRequest: 2)
        let client = client(http)
        let task = Task { try await client.search(artist: "Massive Attack", album: "Blue Lines") }
        do {
            _ = try await task.value
            XCTFail("Expected late image response to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationWhileWaitingForSearchSlotDoesNotStartAnotherRequest() async throws {
        let http = AppleArtworkHTTPStub(responses: [.success(searchResponse([]))])
        let client = AppleArtworkClient(httpClient: http, minimumInterval: .milliseconds(100))
        _ = try await client.search(artist: "Massive Attack", album: "Blue Lines")
        let task = Task { try await client.search(artist: "Massive Attack", album: "Mezzanine") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before the next request")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    private func client(_ http: AppleArtworkHTTPStub) -> AppleArtworkClient {
        AppleArtworkClient(httpClient: http, minimumInterval: .zero)
    }

    private func response(_ data: Data = Data(), status: Int = 200) -> HTTPResponse {
        HTTPResponse(data: data, statusCode: status, headers: [:])
    }

    private func searchResponse(_ albums: [[String: Any]]) -> HTTPResponse {
        response(try! JSONSerialization.data(withJSONObject: ["results": albums]))
    }

    private func album(
        id: Int = 1, title: String = "Blue Lines", artist: String = "Massive Attack",
        imageURL: String = "https://is1-ssl.mzstatic.com/image/cover/100x100bb.jpg",
        collectionURL: String? = nil
    ) -> [String: Any] {
        ["wrapperType": "collection", "collectionType": "Album", "collectionId": id,
         "collectionName": title, "artistName": artist, "releaseDate": "1991-04-08T07:00:00Z",
         "artworkUrl100": imageURL,
         "collectionViewUrl": collectionURL ?? "https://music.apple.com/us/album/blue-lines/\(id)"]
    }

    private func imageData(width: Int = 7, height: Int = 5) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor AppleArtworkHTTPStub: HTTPDataLoading {
    private var responses: [Result<HTTPResponse, Error>]
    private let cancelOnRequest: Int?
    private var requests: [URLRequest] = []

    init(responses: [Result<HTTPResponse, Error>], cancelOnRequest: Int? = nil) {
        self.responses = responses
        self.cancelOnRequest = cancelOnRequest
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if requests.count == cancelOnRequest { withUnsafeCurrentTask { $0?.cancel() } }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] { requests }
}
