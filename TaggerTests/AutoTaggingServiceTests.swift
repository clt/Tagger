import Foundation
import XCTest
@testable import Tagger

final class AutoTaggingServiceTests: XCTestCase {
    func testAppleLookupIsSeparateFromTextAndCoverResolution() async throws {
        let apple = AppleArtworkServiceStub()
        let service = AutoTaggingService(musicBrainz: AutoTagMusicBrainzStub(),
            coverArt: AutoTagCoverArtStub(), appleArtwork: apple)
        let outcome = try await service.search(request())
        let local = try XCTUnwrap(outcome.candidates.first)
        _ = try await service.resolve(local, for: request())
        _ = try await service.resolve(candidate(releaseID: releaseID), for: request())
        let initialCalls = await apple.callCount()
        XCTAssertEqual(initialCalls, 0)
        let result = try await service.searchAppleArtwork(artist: "Portishead", album: "Dummy")
        let calls = await apple.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.artworks.first?.title, "Dummy")
    }

    func testFilenameSearchAndResolutionNeverContactMusicBrainz() async throws {
        let remote = AutoTagMusicBrainzStub()
        let coverArt = AutoTagCoverArtStub()
        let service = AutoTaggingService(musicBrainz: remote, coverArt: coverArt)
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
        let coverRequests = await coverArt.recordedReleaseIDs()
        XCTAssertTrue(coverRequests.isEmpty)
        XCTAssertNil(proposal.artwork)
    }

    func testOnlineSearchUsesOnlyExplicitSeedAndKeepsFilenameSuggestion() async throws {
        let remoteCandidate = candidate(releaseID: releaseID)
        let remote = AutoTagMusicBrainzStub(candidates: [remoteCandidate])
        let coverArt = AutoTagCoverArtStub()
        let service = AutoTaggingService(musicBrainz: remote, coverArt: coverArt)
        let seed = MusicBrainzSearchSeed(
            title: "User Corrected Title", artist: "User Corrected Artist", album: "User Corrected Album"
        )

        let outcome = try await service.search(request(searchSeed: seed))

        XCTAssertEqual(outcome.candidates.map(\.source), [.filename, .musicBrainz])
        XCTAssertEqual(outcome.candidates.last, remoteCandidate)
        let sentSeeds = await remote.recordedSeeds()
        XCTAssertEqual(sentSeeds, [seed])
        XCTAssertNil(outcome.warningMessage)
        let coverRequests = await coverArt.recordedReleaseIDs()
        XCTAssertTrue(coverRequests.isEmpty)
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

    func testReleaseResolutionEnrichesTextProposalWithArtwork() async throws {
        let cover = artwork()
        let remote = AutoTagMusicBrainzStub()
        let coverArt = AutoTagCoverArtStub(result: .success(cover))
        let service = AutoTaggingService(musicBrainz: remote, coverArt: coverArt)
        let candidate = candidate(releaseID: releaseID)

        let proposal = try await service.resolve(candidate, for: request())

        XCTAssertEqual(proposal.candidate, candidate)
        XCTAssertEqual(proposal.values, candidate.preview)
        XCTAssertEqual(proposal.artwork, cover)
        XCTAssertNil(proposal.artworkMessage)
        let coverRequests = await coverArt.recordedReleaseIDs()
        let resolutions = await remote.resolutionCount()
        XCTAssertEqual(coverRequests, [releaseID])
        XCTAssertEqual(resolutions, 1)
    }

    func testMissingCoverKeepsTextProposalWithInformationalMessage() async throws {
        let service = AutoTaggingService(
            musicBrainz: AutoTagMusicBrainzStub(), coverArt: AutoTagCoverArtStub()
        )
        let candidate = candidate(releaseID: releaseID)

        let proposal = try await service.resolve(candidate, for: request())

        XCTAssertEqual(proposal.values, candidate.preview)
        XCTAssertNil(proposal.artwork)
        XCTAssertEqual(proposal.artworkMessage, "No front cover is available for this release.")
    }

    func testCoverFailureKeepsTextProposalWithUsefulWarning() async throws {
        let service = AutoTaggingService(
            musicBrainz: AutoTagMusicBrainzStub(),
            coverArt: AutoTagCoverArtStub(result: .failure(CoverArtArchiveError.httpStatus(503)))
        )
        let candidate = candidate(releaseID: releaseID)

        let proposal = try await service.resolve(candidate, for: request())

        XCTAssertEqual(proposal.values, candidate.preview)
        XCTAssertNil(proposal.artwork)
        XCTAssertTrue(proposal.artworkMessage?.contains("503") == true)
        XCTAssertTrue(proposal.artworkMessage?.contains("Text tag suggestions are still available") == true)
    }

    func testRecordingOnlyResolutionDoesNotRequestArtwork() async throws {
        let coverArt = AutoTagCoverArtStub(result: .success(artwork()))
        let service = AutoTaggingService(musicBrainz: AutoTagMusicBrainzStub(), coverArt: coverArt)

        let proposal = try await service.resolve(candidate(), for: request())

        XCTAssertNil(proposal.artwork)
        XCTAssertNil(proposal.artworkMessage)
        let coverRequests = await coverArt.recordedReleaseIDs()
        XCTAssertTrue(coverRequests.isEmpty)
    }

    func testMusicBrainzResolutionFailureDoesNotRequestArtwork() async {
        let coverArt = AutoTagCoverArtStub()
        let service = AutoTaggingService(
            musicBrainz: AutoTagMusicBrainzStub(resolutionError: .unavailable), coverArt: coverArt
        )

        do {
            _ = try await service.resolve(candidate(releaseID: releaseID), for: request())
            XCTFail("Expected metadata resolution failure")
        } catch {
            XCTAssertEqual(error as? AutoTagMusicBrainzStub.SearchError, .unavailable)
        }
        let coverRequests = await coverArt.recordedReleaseIDs()
        XCTAssertTrue(coverRequests.isEmpty)
    }

    func testCoverCancellationIsNotConvertedToAWarning() async {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            let service = AutoTaggingService(
                musicBrainz: AutoTagMusicBrainzStub(),
                coverArt: AutoTagCoverArtStub(result: .failure(error))
            )
            do {
                _ = try await service.resolve(candidate(releaseID: releaseID), for: request())
                XCTFail("Expected cover cancellation to propagate")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testLateCoverResultIsDiscardedAfterCancellation() async throws {
        let service = AutoTaggingService(
            musicBrainz: AutoTagMusicBrainzStub(),
            coverArt: AutoTagCoverArtStub(result: .success(artwork()), cancelBeforeReturning: true)
        )
        let candidate = candidate(releaseID: releaseID)
        let request = request()
        let task = Task { try await service.resolve(candidate, for: request) }

        do {
            _ = try await task.value
            XCTFail("Expected a late cover result to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationAfterTextResolutionPreventsCoverRequest() async {
        let coverArt = AutoTagCoverArtStub()
        let service = AutoTaggingService(
            musicBrainz: AutoTagMusicBrainzStub(cancelBeforeReturning: true), coverArt: coverArt
        )
        let candidate = candidate(releaseID: releaseID)
        let request = request()
        let task = Task { try await service.resolve(candidate, for: request) }

        do {
            _ = try await task.value
            XCTFail("Expected cancelled resolution to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let coverRequests = await coverArt.recordedReleaseIDs()
        XCTAssertTrue(coverRequests.isEmpty)
    }

    func testCancellationAfterSearchDiscardsLateCandidates() async {
        let service = AutoTaggingService(
            musicBrainz: AutoTagMusicBrainzStub(cancelBeforeReturning: true),
            coverArt: AutoTagCoverArtStub()
        )
        let request = request(searchSeed: MusicBrainzSearchSeed(title: "Roads", artist: nil, album: nil))
        let task = Task { try await service.search(request) }

        do {
            _ = try await task.value
            XCTFail("Expected cancelled search to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private let releaseID = "f4cf6b7b-5d14-4f30-8a83-50a70591198f"

    private func artwork() -> AutoTagArtwork {
        AutoTagArtwork(
            data: Data([0x01, 0x02]),
            sourceURL: URL(string: "https://coverartarchive.org/release/\(releaseID)/front-1200")!
        )
    }

    private func request(searchSeed: MusicBrainzSearchSeed? = nil) -> AutoTagSearchRequest {
        AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/tmp/TaggerAutoTagServiceTests/01 - Portishead - Roads.mp3"),
            currentDraft: ID3TagDraft(),
            searchSeed: searchSeed
        )
    }

    private func candidate(releaseID: String? = nil) -> AutoTagCandidate {
        AutoTagCandidate(
            id: "remote", source: .musicBrainz, title: "Roads", subtitle: "Portishead • Dummy",
            matchScore: 100,
            reference: .musicBrainz(recordingID: "recording", releaseID: releaseID),
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
    private let resolutionError: SearchError?
    private let cancelBeforeReturning: Bool
    private var seeds: [MusicBrainzSearchSeed] = []
    private var resolutions = 0

    init(
        candidates: [AutoTagCandidate] = [],
        searchError: SearchError? = nil,
        resolutionError: SearchError? = nil,
        cancelBeforeReturning: Bool = false
    ) {
        self.candidates = candidates
        self.searchError = searchError
        self.resolutionError = resolutionError
        self.cancelBeforeReturning = cancelBeforeReturning
    }

    func search(seed: MusicBrainzSearchSeed) async throws -> [AutoTagCandidate] {
        seeds.append(seed)
        if searchError == .cancelled { throw CancellationError() }
        if let searchError { throw searchError }
        if cancelBeforeReturning { withUnsafeCurrentTask { $0?.cancel() } }
        return candidates
    }

    func resolve(candidate: AutoTagCandidate, request: AutoTagSearchRequest) async throws -> AutoTagProposal {
        resolutions += 1
        if resolutionError == .cancelled { throw CancellationError() }
        if let resolutionError { throw resolutionError }
        if cancelBeforeReturning { withUnsafeCurrentTask { $0?.cancel() } }
        return AutoTagProposal(candidate: candidate, values: candidate.preview)
    }

    func recordedSeeds() -> [MusicBrainzSearchSeed] { seeds }
    func resolutionCount() -> Int { resolutions }
}

private actor AutoTagCoverArtStub: CoverArtFetching {
    private let result: Result<AutoTagArtwork?, Error>
    private let cancelBeforeReturning: Bool
    private var releaseIDs: [String] = []

    init(result: Result<AutoTagArtwork?, Error> = .success(nil), cancelBeforeReturning: Bool = false) {
        self.result = result
        self.cancelBeforeReturning = cancelBeforeReturning
    }

    func frontCover(forReleaseID releaseID: String) async throws -> AutoTagArtwork? {
        releaseIDs.append(releaseID)
        if cancelBeforeReturning { withUnsafeCurrentTask { $0?.cancel() } }
        return try result.get()
    }

    func recordedReleaseIDs() -> [String] { releaseIDs }
}

private actor AppleArtworkServiceStub: AppleArtworkSearching {
    private var calls = 0
    func callCount() -> Int { calls }
    func search(artist: String, album: String) async throws -> ArtworkSearchOutcome {
        calls += 1
        return ArtworkSearchOutcome(artworks: [AutoTagArtwork(data: Data([1]),
            sourceURL: URL(string: "https://music.apple.com/us/album/dummy/123")!,
            provider: .appleCatalog, title: album, subtitle: artist)], warningMessage: nil)
    }
}
