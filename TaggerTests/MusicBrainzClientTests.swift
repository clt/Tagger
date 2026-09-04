import Foundation
import XCTest
@testable import Tagger

final class MusicBrainzClientTests: XCTestCase {
    func testSearchBuildsPrivateGETAndMapsReleaseCandidates() async throws {
        let recordingID = "4e43d873-7b8a-4b95-97e6-4f692b1a0c75"
        let releaseID = "f4cf6b7b-5d14-4f30-8a83-50a70591198f"
        let response = """
        {
          "recordings": [{
            "id": "\(recordingID)",
            "score": "98",
            "title": "Roads",
            "artist-credit": [
              {"name": "Portishead", "joinphrase": " feat. "},
              {"name": "Guest"}
            ],
            "first-release-date": "1994-08-22",
            "releases": [{
              "id": "\(releaseID)",
              "title": "Dummy",
              "status": "Official",
              "date": "1994-08-22",
              "country": "GB",
              "artist-credit": [{"name": "Portishead"}]
            }]
          }]
        }
        """
        let http = MusicBrainzHTTPStub(responses: [
            HTTPResponse(data: Data(response.utf8), statusCode: 200, headers: [:]),
        ])
        let client = MusicBrainzClient(
            httpClient: http,
            userAgent: "Tagger/Test (https://github.com/clt/Tagger)",
            minimumInterval: .zero
        )

        let candidates = try await client.search(
            seed: MusicBrainzSearchSeed(
                title: "Roads (Live)",
                artist: "Portishead",
                album: "Dummy"
            )
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].id, "musicbrainz:\(recordingID):\(releaseID)")
        XCTAssertEqual(candidates[0].title, "Roads")
        XCTAssertEqual(candidates[0].subtitle, "Portishead feat. Guest • Dummy • 1994 • GB")
        XCTAssertEqual(candidates[0].matchScore, 98)
        XCTAssertEqual(candidates[0].preview.albumArtist, "Portishead")
        XCTAssertEqual(candidates[0].preview.year, "1994")

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertNil(requests[0].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "User-Agent"),
            "Tagger/Test (https://github.com/clt/Tagger)"
        )
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "musicbrainz.org")
        XCTAssertEqual(components.path, "/ws/2/recording")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["fmt"]!, "json")
        XCTAssertEqual(items["limit"]!, "10")
        XCTAssertEqual(
            items["query"]!,
            #"recording:"Roads \(Live\)" AND artist:"Portishead" AND release:"Dummy""#
        )
        XCTAssertFalse(try XCTUnwrap(requests[0].url?.absoluteString).contains("/Music/"))
    }

    func testResolveMapsExactTrackAndMediumWithoutTouchingUnsupportedFields() async throws {
        let recordingID = "4e43d873-7b8a-4b95-97e6-4f692b1a0c75"
        let releaseID = "f4cf6b7b-5d14-4f30-8a83-50a70591198f"
        let response = """
        {
          "title": "Dummy",
          "date": "1994-08-22",
          "artist-credit": [{"name": "Portishead"}],
          "media": [
            {"position": 1, "tracks": [{
              "position": 3,
              "title": "Other Track",
              "recording": {"id": "11111111-1111-1111-1111-111111111111"}
            }]},
            {"position": 2, "tracks": [{
              "position": 8,
              "title": "Roads",
              "artist-credit": [{"name": "Portishead"}],
              "recording": {"id": "\(recordingID)", "title": "Roads"}
            }]}
          ]
        }
        """
        let http = MusicBrainzHTTPStub(responses: [
            HTTPResponse(data: Data(response.utf8), statusCode: 200, headers: [:]),
        ])
        let client = MusicBrainzClient(
            httpClient: http,
            minimumInterval: .zero
        )
        let preview = AutoTagValues(
            title: "Roads",
            artist: "Portishead",
            album: "Dummy",
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            year: "1994"
        )
        let candidate = AutoTagCandidate(
            id: "musicbrainz:\(recordingID):\(releaseID)",
            source: .musicBrainz,
            title: "Roads",
            subtitle: "Portishead • Dummy",
            matchScore: 100,
            reference: .musicBrainz(recordingID: recordingID, releaseID: releaseID),
            preview: preview
        )
        let request = AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/Private/Library/08 - Roads.mp3"),
            currentDraft: ID3TagDraft(comment: "Keep", lyrics: "Keep lyrics")
        )

        let proposal = try await client.resolve(candidate: candidate, request: request)

        XCTAssertEqual(proposal.values.title, "Roads")
        XCTAssertEqual(proposal.values.artist, "Portishead")
        XCTAssertEqual(proposal.values.album, "Dummy")
        XCTAssertEqual(proposal.values.albumArtist, "Portishead")
        XCTAssertEqual(proposal.values.trackNumber, "8")
        XCTAssertEqual(proposal.values.discNumber, "2")
        XCTAssertEqual(proposal.values.year, "1994")

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/ws/2/release/\(releaseID)")
        XCTAssertFalse(try XCTUnwrap(requests[0].url?.absoluteString).contains("Private"))
    }

    func testHTTPFailureAndMalformedJSONBecomeStableErrors() async {
        let unavailableHTTP = MusicBrainzHTTPStub(responses: [
            HTTPResponse(data: Data(), statusCode: 503, headers: [:]),
        ])
        let unavailableClient = MusicBrainzClient(
            httpClient: unavailableHTTP,
            minimumInterval: .zero
        )

        do {
            _ = try await unavailableClient.search(
                seed: MusicBrainzSearchSeed(title: "Roads", artist: nil, album: nil)
            )
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? MusicBrainzError, .httpStatus(503))
        }

        let malformedHTTP = MusicBrainzHTTPStub(responses: [
            HTTPResponse(data: Data("not json".utf8), statusCode: 200, headers: [:]),
        ])
        let malformedClient = MusicBrainzClient(
            httpClient: malformedHTTP,
            minimumInterval: .zero
        )
        do {
            _ = try await malformedClient.search(
                seed: MusicBrainzSearchSeed(title: "Roads", artist: nil, album: nil)
            )
            XCTFail("Expected a decoding error")
        } catch {
            XCTAssertEqual(error as? MusicBrainzError, .malformedResponse)
        }
    }

    func testSearchRejectsBlankQueryAndMissingRecordingsEnvelope() async {
        let http = MusicBrainzHTTPStub(responses: [response(#"{"error":"unexpected"}"#)])
        let client = MusicBrainzClient(httpClient: http, minimumInterval: .zero)

        do {
            _ = try await client.search(seed: seed(" \n "))
            XCTFail("Expected a blank search to be rejected")
        } catch {
            XCTAssertEqual(error as? MusicBrainzError, .invalidRequest)
        }
        let requestsBeforeValidQuery = await http.recordedRequests()
        XCTAssertTrue(requestsBeforeValidQuery.isEmpty)

        do {
            _ = try await client.search(seed: seed("Roads"))
            XCTFail("Expected an invalid search response to be rejected")
        } catch {
            XCTAssertEqual(error as? MusicBrainzError, .malformedResponse)
        }
    }

    func testSearchRejectsUnusableMatchesAndIgnoresInvalidScore() async throws {
        let http = MusicBrainzHTTPStub(responses: [response("""
        {"recordings":[
          {"id":"not-a-recording-id","title":"Roads"},
          {"id":"\(recordingID)","title":" "},
          {"id":"\(recordingID)","title":"Video","video":true},
          {"id":"\(recordingID)","title":"Roads","score":\(Int.max),
           "first-release-date":"0000-01-01",
           "releases":[{"id":"not-a-release-id","title":"Wrong release"}]}
        ]}
        """)])
        let client = MusicBrainzClient(httpClient: http, minimumInterval: .zero)

        let candidates = try await client.search(seed: seed("Roads"))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.title, "Roads")
        XCTAssertNil(candidates.first?.matchScore)
        XCTAssertNil(candidates.first?.preview.year)
        XCTAssertNil(candidates.first?.preview.album)
        XCTAssertEqual(
            candidates.first?.reference,
            .musicBrainz(recordingID: recordingID, releaseID: nil)
        )
    }

    func testResolveRejectsMissingRecordingAndAmbiguousRelease() async {
        let cases: [(String, MusicBrainzError)] = [
            (#"{"media":[{"position":1,"tracks":[]}]}"#, .recordingMissingFromRelease),
            ("""
             {"media":[{"position":1,"tracks":[
               {"position":1,"recording":{"id":"\(recordingID)"}},
               {"position":2,"recording":{"id":"\(recordingID)"}}
             ]}]}
             """, .ambiguousRelease),
        ]
        for (json, expectedError) in cases {
            let http = MusicBrainzHTTPStub(responses: [response(json)])
            let client = MusicBrainzClient(httpClient: http, minimumInterval: .zero)
            do {
                _ = try await client.resolve(candidate: releaseCandidate(), request: request())
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? MusicBrainzError, expectedError)
            }
        }
    }

    func testResolveUsesBothDiscAndTrackToDisambiguateRepeatedRecording() async throws {
        let http = MusicBrainzHTTPStub(responses: [response("""
        {"title":"Album","media":[
          {"position":1,"tracks":[
            {"position":2,"title":"First Disc","recording":{"id":"\(recordingID)"}}
          ]},
          {"position":2,"tracks":[
            {"position":1,"title":"First Track","recording":{"id":"\(recordingID)"}},
            {"position":2,"title":"Chosen Track","recording":{"id":"\(recordingID)"}}
          ]}
        ]}
        """)])
        let client = MusicBrainzClient(httpClient: http, minimumInterval: .zero)
        let request = request(draft: ID3TagDraft(trackNumber: "2", discNumber: "2"))

        let proposal = try await client.resolve(candidate: releaseCandidate(), request: request)

        XCTAssertEqual(proposal.values.title, "Chosen Track")
        XCTAssertEqual(proposal.values.trackNumber, "2")
        XCTAssertEqual(proposal.values.discNumber, "2")
    }

    func testResolveDoesNotProposeInvalidTrackDiscOrYear() async throws {
        let http = MusicBrainzHTTPStub(responses: [response("""
        {"date":"0000-01-01","media":[{"position":0,"tracks":[
          {"position":-1,"recording":{"id":"\(recordingID)"}}
        ]}]}
        """)])
        let client = MusicBrainzClient(httpClient: http, minimumInterval: .zero)

        let proposal = try await client.resolve(candidate: releaseCandidate(), request: request())

        XCTAssertNil(proposal.values.trackNumber)
        XCTAssertNil(proposal.values.discNumber)
        XCTAssertNil(proposal.values.year)
    }

    func testCacheReusesResponsesAndEvictsLeastRecentlyUsedEntry() async throws {
        let http = MusicBrainzHTTPStub(responses: Array(repeating: response(#"{"recordings":[]}"#), count: 4))
        let client = MusicBrainzClient(
            httpClient: http,
            minimumInterval: .zero,
            maximumCacheEntries: 2
        )

        for title in ["A", "B", "A", "C", "A", "B"] {
            _ = try await client.search(seed: seed(title))
        }

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 4, "The recently reused A entry should survive insertion of C")
    }

    func testCacheByteLimitDoesNotRetainOversizedEntry() async throws {
        let body = response(#"{"recordings":[]}"#)
        let http = MusicBrainzHTTPStub(responses: [body, body])
        let client = MusicBrainzClient(
            httpClient: http,
            minimumInterval: .zero,
            maximumCacheBytes: body.data.count - 1
        )

        _ = try await client.search(seed: seed("Roads"))
        _ = try await client.search(seed: seed("Roads"))

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testMalformedAndOversizedResponsesAreNotCached() async throws {
        let http = MusicBrainzHTTPStub(responses: [
            response("not json"),
            HTTPResponse(
                data: Data(repeating: 0x20, count: HTTPResponse.maximumDataSize + 1),
                statusCode: 200,
                headers: [:]
            ),
            response(#"{"recordings":[]}"#),
        ])
        let client = MusicBrainzClient(httpClient: http, minimumInterval: .zero)

        for expectedError in [MusicBrainzError.malformedResponse, .responseTooLarge] {
            do {
                _ = try await client.search(seed: seed("Roads"))
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? MusicBrainzError, expectedError)
            }
        }
        let candidates = try await client.search(seed: seed("Roads"))
        XCTAssertTrue(candidates.isEmpty)
        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    private let recordingID = "4e43d873-7b8a-4b95-97e6-4f692b1a0c75"
    private let releaseID = "f4cf6b7b-5d14-4f30-8a83-50a70591198f"

    private func seed(_ title: String) -> MusicBrainzSearchSeed {
        MusicBrainzSearchSeed(title: title, artist: nil, album: nil)
    }

    private func response(_ json: String) -> HTTPResponse {
        HTTPResponse(data: Data(json.utf8), statusCode: 200, headers: [:])
    }

    private func request(draft: ID3TagDraft = ID3TagDraft()) -> AutoTagSearchRequest {
        AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Roads.mp3"),
            currentDraft: draft
        )
    }

    private func releaseCandidate() -> AutoTagCandidate {
        AutoTagCandidate(
            id: "musicbrainz:\(recordingID):\(releaseID)",
            source: .musicBrainz,
            title: "Roads",
            subtitle: "Portishead",
            matchScore: 100,
            reference: .musicBrainz(recordingID: recordingID, releaseID: releaseID),
            preview: AutoTagValues(title: "Roads", artist: "Portishead")
        )
    }
}

private actor MusicBrainzHTTPStub: HTTPDataLoading {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
