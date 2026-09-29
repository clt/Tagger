import AppKit
import AudioMarker
import Foundation
import XCTest
@testable import Tagger

final class LibrarySessionFolderSummaryTests: XCTestCase {
    @MainActor
    func testOpeningFolderSummarizesImmediateAudioFilesWithoutSelectingOrSaving() async throws {
        let fixture = try makeFolder(files: ["01.mp3", "02.m4a", "notes.txt", "nested/03.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("01.mp3")
        let second = fixture.appendingPathComponent("02.m4a")
        let nested = fixture.appendingPathComponent("nested/03.mp3")
        let metadata = SummaryTestMetadata(tags: [
            first: loaded(first, draft: ID3TagDraft(artist: "Track Artist", album: "Album", albumArtist: "Album Artist")),
            second: loaded(second, draft: ID3TagDraft(artist: "Another Artist", album: "Album", albumArtist: "Album Artist")),
            nested: loaded(nested, draft: ID3TagDraft(artist: "Nested Artist", album: "Nested Album")),
        ])
        let session = open(fixture, metadata: metadata)
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }

        XCTAssertEqual(session.folderMetadataSummary.artistText, "Album Artist")
        XCTAssertEqual(session.folderMetadataSummary.albumText, "Album")
        XCTAssertEqual(session.folderMetadataSummary.fileCount, 2)
        XCTAssertNil(session.folderMetadataSummary.artworkData)
        XCTAssertEqual(session.folderMetadataSummary.artworkPlaceholder, "No cover")
        XCTAssertTrue(session.selectedFileURLs.isEmpty)
        XCTAssertNil(session.draft)
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        let reads = await metadata.readURLs()
        let writes = await metadata.saveURLs()
        XCTAssertEqual(reads, [first, second])
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor
    func testMissingMixedAndUnreadableMetadataAreNonfatal() async throws {
        let fixture = try makeFolder(files: ["01.mp3", "02.mp3", "03.mp3", "04.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("01.mp3")
        let second = fixture.appendingPathComponent("02.mp3")
        let third = fixture.appendingPathComponent("03.mp3")
        let metadata = SummaryTestMetadata(tags: [
            first: loaded(first, draft: ID3TagDraft(artist: "One", album: "First")),
            second: loaded(second, draft: ID3TagDraft(artist: "Two", album: "Second")),
            third: loaded(third, draft: ID3TagDraft()),
        ])
        let session = open(fixture, metadata: metadata)
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }

        XCTAssertEqual(session.folderMetadataSummary.artistText, "Multiple artists")
        XCTAssertEqual(session.folderMetadataSummary.albumText, "Multiple albums")
        XCTAssertEqual(session.folderMetadataSummary.fileCount, 4)
        XCTAssertEqual(session.folderMetadataSummary.unreadableCount, 1)
        XCTAssertEqual(session.folderMetadataSummary.missingMetadataCount, 1)
        XCTAssertNil(session.presentedError)
        let writes = await metadata.saveURLs()
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor
    func testUntaggedFolderShowsPlaceholders() async throws {
        let fixture = try makeFolder(files: ["untagged.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("untagged.mp3")
        let metadata = SummaryTestMetadata(tags: [file: loaded(file, draft: ID3TagDraft())])
        let session = open(fixture, metadata: metadata)
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }

        XCTAssertEqual(session.folderMetadataSummary.artistText, "Unknown artist")
        XCTAssertEqual(session.folderMetadataSummary.albumText, "Unknown album")
        XCTAssertEqual(session.folderMetadataSummary.artworkPlaceholder, "No cover")
        XCTAssertEqual(session.folderMetadataSummary.missingArtworkCount, 1)
    }

    @MainActor
    func testSingleDraftAndArtworkUpdateImmediatelyRevertAndOnlyExplicitSavePersists() async throws {
        let fixture = try makeFolder(files: ["track.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("track.mp3")
        let original = ID3TagDraft(artist: "Original Artist", album: "Original Album", artworkData: try artwork())
        let metadata = SummaryTestMetadata(tags: [file: loaded(file, draft: original)])
        let session = open(fixture, metadata: metadata)
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }
        XCTAssertNotNil(session.folderMetadataSummary.artworkData)
        session.requestSelectEntries([file])
        try await waitUntil { !session.isLoadingTag }

        session.draft?.artist = "Draft Artist"
        session.draft?.album = "Draft Album"
        session.draft?.artworkData = nil
        try await waitUntil {
            session.folderMetadataSummary.artistText == "Draft Artist"
                && session.folderMetadataSummary.albumText == "Draft Album"
                && session.folderMetadataSummary.artworkData == nil
        }
        XCTAssertTrue(session.folderSummaryHasUnsavedChanges)
        let writesBeforeSave = await metadata.saveURLs()
        XCTAssertTrue(writesBeforeSave.isEmpty)
        let diskBeforeSave = await metadata.storedDraft(file)
        XCTAssertEqual(diskBeforeSave, original)

        session.revert()
        try await waitUntil {
            session.folderMetadataSummary.artistText == "Original Artist"
                && session.folderMetadataSummary.artworkData != nil
        }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        session.draft?.album = "Saved Album"
        let didSave = await session.save()
        XCTAssertTrue(didSave)
        session.requestSelectEntries([])
        try await waitUntil { session.folderMetadataSummary.albumText == "Saved Album" }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        let writesAfterSave = await metadata.saveURLs()
        XCTAssertEqual(writesAfterSave, [file])
    }

    @MainActor
    func testBatchSummaryRespectsApplyAndRevertThenRetainsSavedValuesAfterDeselection() async throws {
        let fixture = try makeFolder(files: ["01.mp3", "02.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("01.mp3")
        let second = fixture.appendingPathComponent("02.mp3")
        let original = ID3TagDraft(artist: "Original Artist", album: "Original Album")
        let metadata = SummaryTestMetadata(tags: [first: loaded(first, draft: original), second: loaded(second, draft: original)])
        let session = open(fixture, metadata: metadata)
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }
        session.requestSelectEntries([first, second])
        try await waitUntil { !session.isLoadingTag }

        session.batchDraft?.artist.text = "Batch Artist"
        try await waitUntil { session.folderMetadataSummary.artistText == "Batch Artist" }
        XCTAssertTrue(session.folderSummaryHasUnsavedChanges)
        session.batchDraft?.artist.isApplied = false
        try await waitUntil { session.folderMetadataSummary.artistText == "Original Artist" }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        session.batchDraft?.album.text = "Batch Album"
        try await waitUntil { session.folderMetadataSummary.albumText == "Batch Album" }
        session.revert()
        try await waitUntil { session.folderMetadataSummary.albumText == "Original Album" }
        let writesBeforeSave = await metadata.saveURLs()
        XCTAssertTrue(writesBeforeSave.isEmpty)

        session.batchDraft?.album.text = "Saved Album"
        let didSave = await session.save()
        XCTAssertTrue(didSave)
        session.requestSelectEntries([])
        try await waitUntil { session.folderMetadataSummary.albumText == "Saved Album" }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        let writes = await metadata.saveURLs()
        XCTAssertEqual(writes, [first, second])
    }

    @MainActor
    func testPartialBatchSaveSummaryReflectsSuccessfulFilesAfterRevert() async throws {
        let fixture = try makeFolder(files: ["01.mp3", "02.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("01.mp3")
        let second = fixture.appendingPathComponent("02.mp3")
        let original = ID3TagDraft(artist: "Artist", album: "Original Album")
        let metadata = SummaryTestMetadata(
            tags: [first: loaded(first, draft: original), second: loaded(second, draft: original)],
            failingSaveURLs: [second]
        )
        let session = open(fixture, metadata: metadata)
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }
        session.requestSelectEntries([first, second])
        try await waitUntil { !session.isLoadingTag }
        session.batchDraft?.album.text = "Saved Album"
        let didSave = await session.save()
        XCTAssertFalse(didSave)
        try await waitUntil { session.folderMetadataSummary.albumText == "Saved Album" }
        XCTAssertTrue(session.folderSummaryHasUnsavedChanges)

        session.revert()
        session.requestSelectEntries([])
        try await waitUntil { session.folderMetadataSummary.albumText == "Multiple albums" }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
    }

    @MainActor
    func testDelayedPreviousFolderResultCannotReplaceCurrentFolderSummary() async throws {
        let fixture = try makeFolder(files: ["A/track.mp3", "B/track.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let folderA = fixture.appendingPathComponent("A", isDirectory: true)
        let folderB = fixture.appendingPathComponent("B", isDirectory: true)
        let first = folderA.appendingPathComponent("track.mp3")
        let second = folderB.appendingPathComponent("track.mp3")
        let metadata = SummaryTestMetadata(tags: [
            first: loaded(first, draft: ID3TagDraft(artist: "Artist A", album: "Album A")),
            second: loaded(second, draft: ID3TagDraft(artist: "Artist B", album: "Album B")),
        ], delayedURL: first)
        let session = open(folderA, metadata: metadata)
        try await waitUntil { await metadata.hasSuspendedRead() }
        session.requestSelectFolder(folderB)
        try await waitUntil {
            !session.isLoadingDirectory && !session.isLoadingFolderSummary
                && session.folderMetadataSummary.albumText == "Album B"
        }
        await metadata.releaseRead()
        // The fake deliberately ignores task cancellation, so the old result really returns.
        try await waitUntil { await metadata.didReturnDelayedRead() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(session.selectedFolderURL, folderB)
        XCTAssertEqual(session.folderMetadataSummary.artistText, "Artist B")
        XCTAssertEqual(session.folderMetadataSummary.albumText, "Album B")
        XCTAssertEqual(session.folderMetadataSummary.fileCount, 1)
        XCTAssertFalse(session.isLoadingFolderSummary)
    }

    @MainActor
    func testRenameDuringPausedScanDoesNotReadObsoletePathOrReportUnreadableFile() async throws {
        let fixture = try makeFolder(files: ["01.mp3", "02.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("01.mp3")
        let second = fixture.appendingPathComponent("02.mp3")
        let renamed = fixture.appendingPathComponent("Renamed.mp3")
        let original = ID3TagDraft(artist: "Artist", album: "Album")
        let metadata = SummaryTestMetadata(
            tags: [first: loaded(first, draft: original), second: loaded(second, draft: original)],
            delayedURL: first,
            requireFileExists: true
        )
        let session = open(fixture, metadata: metadata)
        try await waitUntil { await metadata.hasSuspendedRead() }
        session.requestSelectEntries([second])
        try await waitUntil { !session.isLoadingTag }
        session.filenameDraft?.stem = "Renamed"
        let didSave = await session.save()
        XCTAssertTrue(didSave)
        XCTAssertEqual(session.selectedFileURL, renamed)
        await metadata.releaseRead()
        try await waitUntil { !session.isLoadingFolderSummary }
        session.requestSelectEntries([])

        XCTAssertEqual(session.folderMetadataSummary.fileCount, 2)
        XCTAssertEqual(session.folderMetadataSummary.unreadableCount, 0)
        XCTAssertEqual(session.folderMetadataSummary.albumText, "Album")
        let reads = await metadata.readURLs()
        XCTAssertEqual(reads.filter { $0 == second }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: renamed), Data([0]))
    }

    @MainActor
    func testNewerArtworkDraftSurvivesEarlierSaveAndSummaryReflectsUnsavedArtwork() async throws {
        let fixture = try makeFolder(files: ["track.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("track.mp3")
        let artworkA = Data([1])
        let artworkB = Data([2])
        let metadata = SummaryTestMetadata(
            tags: [file: loaded(file, draft: ID3TagDraft(artist: "Artist", album: "Album", artworkData: artworkA))],
            delaySaves: true
        )
        let session = open(fixture, metadata: metadata, summarizer: SummaryTestSummarizer())
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }
        session.requestSelectEntries([file])
        try await waitUntil { !session.isLoadingTag }
        session.draft?.artworkData = artworkB
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkB }
        let saveTask = Task { await session.save() }
        try await waitUntil { await metadata.hasSuspendedSave() }
        // Return to the original image while the earlier B save is still in flight.
        session.draft?.artworkData = artworkA
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkA }
        await metadata.releaseSave()
        let didSave = await saveTask.value
        XCTAssertTrue(didSave)
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkA }
        XCTAssertEqual(session.draft?.artworkData, artworkA)
        XCTAssertEqual(session.originalDraft?.artworkData, artworkB)
        XCTAssertTrue(session.folderSummaryHasUnsavedChanges)
        let savedDraft = await metadata.storedDraft(file)
        XCTAssertEqual(savedDraft?.artworkData, artworkB)
        session.revert()
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkB }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
    }

    @MainActor
    func testBatchArtworkReplacementRemovalAndRevertUpdateFolderSummaryWithoutSaving() async throws {
        let fixture = try makeFolder(files: ["01.mp3", "02.mp3"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("01.mp3")
        let second = fixture.appendingPathComponent("02.mp3")
        let artworkA = Data([1])
        let artworkB = Data([2])
        let original = ID3TagDraft(artist: "Artist", album: "Album", artworkData: artworkA)
        let metadata = SummaryTestMetadata(tags: [first: loaded(first, draft: original), second: loaded(second, draft: original)])
        let session = open(fixture, metadata: metadata, summarizer: SummaryTestSummarizer())
        try await waitUntil { !session.isLoadingDirectory && !session.isLoadingFolderSummary }
        session.requestSelectEntries([first, second])
        try await waitUntil { !session.isLoadingTag }
        session.batchDraft?.artworkData.replace(with: artworkB)
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkB }
        XCTAssertTrue(session.folderSummaryHasUnsavedChanges)
        session.batchDraft?.artworkData.isApplied = false
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkA }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        session.batchDraft?.artworkData.remove()
        try await waitUntil { session.folderMetadataSummary.artworkData == nil }
        XCTAssertEqual(session.folderMetadataSummary.artworkPlaceholder, "No cover")
        session.revert()
        try await waitUntil { session.folderMetadataSummary.artworkData == artworkA }
        XCTAssertFalse(session.folderSummaryHasUnsavedChanges)
        let writes = await metadata.saveURLs()
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor
    private func open(
        _ folder: URL,
        metadata: SummaryTestMetadata,
        summarizer: any FolderMetadataSummarizing = FolderMetadataSummaryService()
    ) -> LibrarySession {
        let session = LibrarySession(metadataService: metadata, folderSummarizer: summarizer)
        // Exercise folder navigation without changing the user's persisted folder bookmark.
        session.rootURL = folder
        session.requestSelectFolder(folder)
        return session
    }

    @MainActor
    private func waitUntil(condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for folder summary state")
        throw SummaryTestError.timeout
    }

    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TaggerFolderSummary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for relativePath in files {
            let url = folder.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: url)
        }
        return folder
    }

    private func loaded(_ url: URL, draft: ID3TagDraft) -> LoadedID3Tag {
        LoadedID3Tag(
            url: url,
            source: AudioFileInfo(),
            draft: draft,
            hadID3v2Tag: false,
            snapshot: AudioFileSnapshot(fileSize: 1, modificationDate: nil, tagFingerprint: Data())
        )
    }

    @MainActor
    private func artwork() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private actor SummaryTestMetadata: ID3MetadataServicing {
    private var tags: [URL: LoadedID3Tag]
    private var reads: [URL] = []
    private var writes: [URL] = []
    private let failingSaveURLs: Set<URL>
    private let delayedURL: URL?
    private var suspendedRead: CheckedContinuation<Void, Never>?
    private var delayedReadReturned = false
    private let requireFileExists: Bool
    private let delaySaves: Bool
    private var suspendedSave: CheckedContinuation<Void, Never>?

    init(
        tags: [URL: LoadedID3Tag],
        failingSaveURLs: Set<URL> = [],
        delayedURL: URL? = nil,
        requireFileExists: Bool = false,
        delaySaves: Bool = false
    ) {
        self.tags = tags
        self.failingSaveURLs = failingSaveURLs
        self.delayedURL = delayedURL
        self.requireFileExists = requireFileExists
        self.delaySaves = delaySaves
    }

    func load(from url: URL) async throws -> LoadedID3Tag {
        reads.append(url)
        if requireFileExists && !FileManager.default.fileExists(atPath: url.path) {
            throw SummaryTestError.unreadable
        }
        guard let tag = tags[url] else { throw SummaryTestError.unreadable }
        if url == delayedURL {
            await withCheckedContinuation { suspendedRead = $0 }
            delayedReadReturned = true
        }
        return tag
    }

    func validateUnchanged(_ loaded: LoadedID3Tag) async throws {}

    func save(_ loaded: LoadedID3Tag, draft: ID3TagDraft) async throws -> LoadedID3Tag {
        writes.append(loaded.url)
        if delaySaves {
            await withCheckedContinuation { suspendedSave = $0 }
        }
        if failingSaveURLs.contains(loaded.url) { throw SummaryTestError.unreadable }
        let saved = LoadedID3Tag(url: loaded.url, source: loaded.source, draft: draft, hadID3v2Tag: loaded.hadID3v2Tag, snapshot: loaded.snapshot)
        tags[loaded.url] = saved
        return saved
    }

    func hasSuspendedSave() -> Bool { suspendedSave != nil }
    func releaseSave() {
        suspendedSave?.resume()
        suspendedSave = nil
    }
    func readURLs() -> [URL] { reads }
    func saveURLs() -> [URL] { writes }
    func storedDraft(_ url: URL) -> ID3TagDraft? { tags[url]?.draft }
    func hasSuspendedRead() -> Bool { suspendedRead != nil }
    func didReturnDelayedRead() -> Bool { delayedReadReturned }
    func releaseRead() {
        suspendedRead?.resume()
        suspendedRead = nil
    }
}

private enum SummaryTestError: Error {
    case unreadable
    case timeout
}

private struct SummaryTestSummarizer: FolderMetadataSummarizing {
    func item(from draft: ID3TagDraft) async -> FolderMetadataItem {
        FolderMetadataItem(
            artist: draft.albumArtist.isEmpty ? draft.artist : draft.albumArtist,
            album: draft.album,
            artwork: draft.artworkData.map { FolderSummaryArtwork(digest: $0, thumbnailData: $0) }
        )
    }
}
