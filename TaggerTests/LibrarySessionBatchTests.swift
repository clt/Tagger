import AudioMarker
import Foundation
import XCTest
@testable import Tagger

final class LibrarySessionBatchTests: XCTestCase {
    @MainActor
    func testBatchLoadAndSaveUseDirectoryOrderAndPreserveUntouchedFields() async throws {
        let firstURL = testURL("01-first.mp3")
        let secondURL = testURL("02-second.mp3")
        let firstArtwork = Data([0x01, 0x02])
        let secondArtwork = Data([0x03, 0x04])
        let firstDraft = ID3TagDraft(
            title: "First Title",
            artist: "First Artist",
            album: "First Album",
            albumArtist: "First Album Artist",
            trackNumber: "1",
            discNumber: "1",
            year: "2001",
            genre: "Rock",
            composer: "First Composer",
            comment: "First Comment",
            lyrics: "First Lyrics",
            artworkData: firstArtwork
        )
        let secondDraft = ID3TagDraft(
            title: "Second Title",
            artist: "Second Artist",
            album: "Second Album",
            albumArtist: "Second Album Artist",
            trackNumber: "2",
            discNumber: "2",
            year: "2002",
            genre: "Jazz",
            composer: "Second Composer",
            comment: "Second Comment",
            lyrics: "Second Lyrics",
            artworkData: secondArtwork
        )
        let metadata = FakeID3MetadataService(tags: [
            firstURL: loadedTag(url: firstURL, draft: firstDraft),
            secondURL: loadedTag(url: secondURL, draft: secondDraft),
        ])
        let session = LibrarySession(metadataService: metadata)
        session.entries = [
            entry(url: secondURL),
            entry(url: firstURL),
        ]

        session.requestSelectEntries([firstURL, secondURL])
        try await waitUntil { !session.isLoadingTag }

        let loadURLs = await metadata.recordedLoadURLs()
        XCTAssertEqual(session.selectedFileURLs, [secondURL, firstURL])
        XCTAssertEqual(loadURLs, [secondURL, firstURL])
        XCTAssertEqual(session.batchDraft?.title.source, .mixed)

        session.batchDraft?.artist.text = "Unified Artist"
        XCTAssertTrue(session.isDirty)
        let didSave = await session.save()
        XCTAssertTrue(didSave)

        let saveCalls = await metadata.recordedSaveCalls()
        let storedSecond = await metadata.storedDraft(for: secondURL)
        let storedFirst = await metadata.storedDraft(for: firstURL)
        XCTAssertEqual(saveCalls.map(\.url), [secondURL, firstURL])

        var expectedSecond = secondDraft
        expectedSecond.artist = "Unified Artist"
        var expectedFirst = firstDraft
        expectedFirst.artist = "Unified Artist"
        XCTAssertEqual(saveCalls.map(\.draft), [expectedSecond, expectedFirst])
        XCTAssertEqual(storedSecond, expectedSecond)
        XCTAssertEqual(storedFirst, expectedFirst)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.batchDraft?.artist.source, .shared("Unified Artist"))
    }

    @MainActor
    func testOneBatchFailureDoesNotStopLaterSavesAndRetainsDirtyEdits() async throws {
        let firstURL = testURL("01-first.mp3")
        let failingURL = testURL("02-failing.mp3")
        let lastURL = testURL("03-last.mp3")
        let firstDraft = ID3TagDraft(title: "First", genre: "Rock")
        let failingDraft = ID3TagDraft(title: "Failing", genre: "Jazz")
        let lastDraft = ID3TagDraft(title: "Last", genre: "Classical")
        let metadata = FakeID3MetadataService(
            tags: [
                firstURL: loadedTag(url: firstURL, draft: firstDraft),
                failingURL: loadedTag(url: failingURL, draft: failingDraft),
                lastURL: loadedTag(url: lastURL, draft: lastDraft),
            ],
            failingSaveURLs: [failingURL]
        )
        let session = LibrarySession(metadataService: metadata)
        session.entries = [
            entry(url: firstURL),
            entry(url: failingURL),
            entry(url: lastURL),
        ]

        session.requestSelectEntries([lastURL, firstURL, failingURL])
        try await waitUntil { !session.isLoadingTag }
        session.batchDraft?.genre.text = "Ambient"

        let didSave = await session.save()
        XCTAssertFalse(didSave)

        let saveCalls = await metadata.recordedSaveCalls()
        let storedFirst = await metadata.storedDraft(for: firstURL)
        let storedFailing = await metadata.storedDraft(for: failingURL)
        let storedLast = await metadata.storedDraft(for: lastURL)
        XCTAssertEqual(saveCalls.map(\.url), [firstURL, failingURL, lastURL])

        var expectedFirst = firstDraft
        expectedFirst.genre = "Ambient"
        var expectedLast = lastDraft
        expectedLast.genre = "Ambient"
        XCTAssertEqual(storedFirst, expectedFirst)
        XCTAssertEqual(storedFailing, failingDraft)
        XCTAssertEqual(storedLast, expectedLast)

        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.batchDraft?.genre.edit, .set("Ambient"))
        XCTAssertEqual(session.batchDraft?.genre.source, .mixed)
        XCTAssertEqual(session.statusMessage, "Saved 2 of 3 files")
        XCTAssertEqual(session.presentedError?.title, "Some Tags Weren’t Saved")
        XCTAssertTrue(session.presentedError?.message.contains(failingURL.lastPathComponent) == true)

        session.batchDraft?.genre.isApplied = false
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.batchDraft?.genre.source, .mixed)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTFail("Timed out waiting for LibrarySession state to settle")
    }

    private func testURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/TaggerBatchTests/\(name)")
    }

    private func entry(url: URL) -> DirectoryEntry {
        DirectoryEntry(
            url: url,
            name: url.lastPathComponent,
            kind: .mp3,
            fileSize: 1_024
        )
    }

    private func loadedTag(url: URL, draft: ID3TagDraft) -> LoadedID3Tag {
        LoadedID3Tag(
            url: url,
            source: AudioFileInfo(),
            draft: draft,
            hadID3v2Tag: false,
            snapshot: AudioFileSnapshot(
                fileSize: 1_024,
                modificationDate: nil,
                tagFingerprint: Data()
            )
        )
    }
}

private actor FakeID3MetadataService: ID3MetadataServicing {
    struct SaveCall: Equatable, Sendable {
        let url: URL
        let draft: ID3TagDraft
    }

    private var tags: [URL: LoadedID3Tag]
    private let failingSaveURLs: Set<URL>
    private var loadURLs: [URL] = []
    private var saveCalls: [SaveCall] = []

    init(
        tags: [URL: LoadedID3Tag],
        failingSaveURLs: Set<URL> = []
    ) {
        self.tags = tags
        self.failingSaveURLs = failingSaveURLs
    }

    func load(from url: URL) async throws -> LoadedID3Tag {
        loadURLs.append(url)
        guard let tag = tags[url] else {
            throw FakeMetadataError.missingTag(url.lastPathComponent)
        }
        return tag
    }

    func validateUnchanged(_ loaded: LoadedID3Tag) async throws {
        guard tags[loaded.url] != nil else {
            throw FakeMetadataError.missingTag(loaded.url.lastPathComponent)
        }
    }

    func save(
        _ loaded: LoadedID3Tag,
        draft: ID3TagDraft
    ) async throws -> LoadedID3Tag {
        saveCalls.append(SaveCall(url: loaded.url, draft: draft))

        if failingSaveURLs.contains(loaded.url) {
            throw FakeMetadataError.forcedSaveFailure(loaded.url.lastPathComponent)
        }

        let saved = LoadedID3Tag(
            url: loaded.url,
            source: loaded.source,
            draft: draft,
            hadID3v2Tag: loaded.hadID3v2Tag,
            snapshot: loaded.snapshot
        )
        tags[loaded.url] = saved
        return saved
    }

    func recordedLoadURLs() -> [URL] {
        loadURLs
    }

    func recordedSaveCalls() -> [SaveCall] {
        saveCalls
    }

    func storedDraft(for url: URL) -> ID3TagDraft? {
        tags[url]?.draft
    }
}

private enum FakeMetadataError: LocalizedError {
    case missingTag(String)
    case forcedSaveFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingTag(let filename):
            return "No fake tag exists for \(filename)."
        case .forcedSaveFailure(let filename):
            return "Forced save failure for \(filename)."
        }
    }
}
