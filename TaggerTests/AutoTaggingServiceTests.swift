import Foundation
import XCTest
@testable import Tagger

final class AutoTaggingServiceTests: XCTestCase {
    func testFilenameSearchAndResolutionNeverContactMusicBrainz() async throws {
        let remote = AutoTagMusicBrainzStub()
        let service = AutoTaggingService(musicBrainz: remote)
        let request = request()

        let outcome = try await service.search(request)
        let candidate = try XCTUnwrap(outcome.candidates.first)
        let proposal = try await service.resolve(candidate, for: request)

        XCTAssertEqual(outcome.candidates.count, 1)
        XCTAssertEqual(candidate.source, .filename)
        XCTAssertEqual(proposal.values.title, "Roads")
        XCTAssertEqual(proposal.values.artist, "Portishead")
        XCTAssertNil(outcome.warningMessage)
        let seeds = await remote.recordedSeeds()
        let resolutions = await remote.resolutionCount()
        XCTAssertTrue(seeds.isEmpty)
        XCTAssertEqual(resolutions, 0)
    }

    func testOnlineSearchUsesOnlyExplicitSeedAndKeepsFilenameSuggestion() async throws {
        let remoteCandidate = candidate()
        let remote = AutoTagMusicBrainzStub(candidates: [remoteCandidate])
        let service = AutoTaggingService(musicBrainz: remote)
        let seed = MusicBrainzSearchSeed(
            title: "User Corrected Title", artist: "User Corrected Artist", album: "User Corrected Album"
        )

        let outcome = try await service.search(request(searchSeed: seed))

        XCTAssertEqual(outcome.candidates.map(\.source), [.filename, .musicBrainz])
        XCTAssertEqual(outcome.candidates.last, remoteCandidate)
        let sentSeeds = await remote.recordedSeeds()
        XCTAssertEqual(sentSeeds, [seed])
        XCTAssertNil(outcome.warningMessage)
    }

    func testNetworkFailureLeavesFilenameSuggestionAvailable() async throws {
        let remote = AutoTagMusicBrainzStub(searchError: .unavailable)
        let service = AutoTaggingService(musicBrainz: remote)

        let outcome = try await service.search(request(
            searchSeed: MusicBrainzSearchSeed(title: "Roads", artist: nil, album: nil)
        ))

        XCTAssertEqual(outcome.candidates.count, 1)
        XCTAssertEqual(outcome.candidates.first?.source, .filename)
        XCTAssertNotNil(outcome.warningMessage)
    }

    func testNetworkFailureWithoutLocalChangesIsReported() async throws {
        let remote = AutoTagMusicBrainzStub(searchError: .unavailable)
        let service = AutoTaggingService(musicBrainz: remote)
        let request = AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/tmp/TaggerAutoTagServiceTests/Roads.mp3"),
            currentDraft: ID3TagDraft(title: "Roads"),
            searchSeed: MusicBrainzSearchSeed(title: "Roads", artist: nil, album: nil)
        )

        do {
            _ = try await service.search(request)
            XCTFail("Expected the network failure to be reported")
        } catch let error as AutoTagMusicBrainzStub.SearchError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testCancellationIsNotConvertedIntoAFilenameFallback() async throws {
        let remote = AutoTagMusicBrainzStub(searchError: .cancelled)
        let service = AutoTaggingService(musicBrainz: remote)

        do {
            _ = try await service.search(request(
                searchSeed: MusicBrainzSearchSeed(title: "Roads", artist: nil, album: nil)
            ))
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Cancellation belongs to the session, which discards stale results.
        }
    }

    private func request(searchSeed: MusicBrainzSearchSeed? = nil) -> AutoTagSearchRequest {
        AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/tmp/TaggerAutoTagServiceTests/01 - Portishead - Roads.mp3"),
            currentDraft: ID3TagDraft(),
            searchSeed: searchSeed
        )
    }

    private func candidate() -> AutoTagCandidate {
        AutoTagCandidate(
            id: "remote", source: .musicBrainz, title: "Roads", subtitle: "Portishead • Dummy",
            matchScore: 100,
            reference: .musicBrainz(recordingID: "recording", releaseID: nil),
            preview: AutoTagValues(title: "Roads", artist: "Portishead", album: "Dummy")
        )
    }
}

private actor AutoTagMusicBrainzStub: MusicBrainzSearching {
    enum SearchError: Error, Equatable {
        case unavailable
        case cancelled
    }

    private let candidates: [AutoTagCandidate]
    private let searchError: SearchError?
    private var seeds: [MusicBrainzSearchSeed] = []
    private var resolutions = 0

    init(candidates: [AutoTagCandidate] = [], searchError: SearchError? = nil) {
        self.candidates = candidates
        self.searchError = searchError
    }

    func search(seed: MusicBrainzSearchSeed) async throws -> [AutoTagCandidate] {
        seeds.append(seed)
        if searchError == .cancelled { throw CancellationError() }
        if let searchError { throw searchError }
        return candidates
    }

    func resolve(candidate: AutoTagCandidate, request: AutoTagSearchRequest) async throws -> AutoTagProposal {
        resolutions += 1
        return AutoTagProposal(candidate: candidate, values: candidate.preview)
    }

    func recordedSeeds() -> [MusicBrainzSearchSeed] { seeds }
    func resolutionCount() -> Int { resolutions }
}
