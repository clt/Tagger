import AudioMarker
import Foundation
import XCTest
@testable import Tagger

final class LibrarySessionFilenameTests: XCTestCase {
    @MainActor
    func testRenameOnlyMigratesSingleFileSessionState() async throws {
        let oldURL = testURL("Original.mp3")
        let newURL = testURL("Renamed.mp3")
        let otherURL = testURL("Alpha.mp3")
        let originalDraft = ID3TagDraft(title: "Original Title")
        let metadata = FilenameTestMetadataService(tags: [
            oldURL: loadedTag(url: oldURL, draft: originalDraft),
        ])
        let renamer = FilenameTestRenamer()
        let session = LibrarySession(fileRenamer: renamer, metadataService: metadata)
        session.entries = [entry(url: oldURL), entry(url: otherURL)]

        session.requestSelectFile(oldURL)
        try await waitUntil { !session.isLoadingTag }
        session.filenameDraft?.stem = "Renamed"

        XCTAssertTrue(session.hasUnsavedFilenameChange)
        XCTAssertFalse(session.hasUnsavedTagChanges)
        XCTAssertTrue(session.canSave)

        let didSave = await session.save()
        let validationCalls = await renamer.validateCalls()
        let renameCalls = await renamer.renameCalls()
        let validatedURLs = await metadata.validatedURLs()
        let savedDrafts = await metadata.savedDrafts()

        XCTAssertTrue(didSave)
        XCTAssertEqual(validationCalls, [
            .init(source: oldURL, fileName: "Renamed.mp3"),
        ])
        XCTAssertEqual(renameCalls, [
            .init(source: oldURL, destination: newURL),
        ])
        XCTAssertEqual(validatedURLs, [oldURL])
        XCTAssertTrue(savedDrafts.isEmpty)

        XCTAssertEqual(session.selectedFileURL, newURL)
        XCTAssertEqual(session.selectedFileURLs, [newURL])
        XCTAssertEqual(session.selectedEntryURLs, [newURL])
        XCTAssertEqual(session.entries.map(\.url), [otherURL, newURL])
        XCTAssertEqual(session.entries.map(\.name), ["Alpha.mp3", "Renamed.mp3"])
        XCTAssertEqual(session.loadedTag?.url, newURL)
        XCTAssertNil(session.loadedTagsByURL[oldURL])
        XCTAssertEqual(session.loadedTagsByURL[newURL]?.url, newURL)
        XCTAssertEqual(session.filenameDraft?.originalFilename, "Renamed.mp3")
        XCTAssertEqual(session.filenameDraft?.proposedFilename, "Renamed.mp3")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.statusMessage, "Renamed to Renamed.mp3")
    }

    @MainActor
    func testRenameCollisionRetainsDirtyFilenameAndOriginalSelection() async throws {
        let oldURL = testURL("Original.mp3")
        let metadata = FilenameTestMetadataService(tags: [
            oldURL: loadedTag(url: oldURL, draft: ID3TagDraft()),
        ])
        let renamer = FilenameTestRenamer(
            validationError: FileRenameError.destinationExists("Taken.mp3")
        )
        let session = LibrarySession(fileRenamer: renamer, metadataService: metadata)
        session.entries = [entry(url: oldURL)]

        session.requestSelectFile(oldURL)
        try await waitUntil { !session.isLoadingTag }
        session.filenameDraft?.stem = "Taken"

        let didSave = await session.save()
        let renameCalls = await renamer.renameCalls()
        let validatedURLs = await metadata.validatedURLs()
        let savedDrafts = await metadata.savedDrafts()

        XCTAssertFalse(didSave)
        XCTAssertEqual(session.selectedFileURL, oldURL)
        XCTAssertEqual(session.filenameDraft?.proposedFilename, "Taken.mp3")
        XCTAssertTrue(session.hasUnsavedFilenameChange)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(renameCalls.isEmpty)
        XCTAssertTrue(validatedURLs.isEmpty)
        XCTAssertTrue(savedDrafts.isEmpty)
        XCTAssertEqual(session.presentedError?.title, "Couldn’t Rename File")
        XCTAssertEqual(
            session.presentedError?.message,
            "A file named “Taken.mp3” already exists in this folder."
        )
    }

    @MainActor
    func testRevertRestoresFilenameWithoutPerformingIO() async throws {
        let url = testURL("Original.mp3")
        let metadata = FilenameTestMetadataService(tags: [
            url: loadedTag(url: url, draft: ID3TagDraft()),
        ])
        let renamer = FilenameTestRenamer()
        let session = LibrarySession(fileRenamer: renamer, metadataService: metadata)
        session.entries = [entry(url: url)]

        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }
        session.filenameDraft?.stem = "Unsaved"
        XCTAssertTrue(session.isDirty)

        session.revert()
        let validationCalls = await renamer.validateCalls()
        let renameCalls = await renamer.renameCalls()
        let savedDrafts = await metadata.savedDrafts()

        XCTAssertEqual(session.filenameDraft?.proposedFilename, "Original.mp3")
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(validationCalls.isEmpty)
        XCTAssertTrue(renameCalls.isEmpty)
        XCTAssertTrue(savedDrafts.isEmpty)
    }

    @MainActor
    func testTagSavePersistsWhenSubsequentRenameFails() async throws {
        let oldURL = testURL("Original.mp3")
        let newURL = testURL("Renamed.mp3")
        let originalDraft = ID3TagDraft(title: "Original Title", artist: "Original Artist")
        let metadata = FilenameTestMetadataService(tags: [
            oldURL: loadedTag(url: oldURL, draft: originalDraft),
        ])
        let renamer = FilenameTestRenamer(
            renameError: FileRenameError.renameFailed("Forced rename failure.")
        )
        let session = LibrarySession(fileRenamer: renamer, metadataService: metadata)
        session.entries = [entry(url: oldURL)]

        session.requestSelectFile(oldURL)
        try await waitUntil { !session.isLoadingTag }
        session.draft?.artist = "Saved Artist"
        session.filenameDraft?.stem = "Renamed"

        let didSave = await session.save()
        let renameCalls = await renamer.renameCalls()

        XCTAssertFalse(didSave)
        XCTAssertEqual(renameCalls, [
            .init(source: oldURL, destination: newURL),
        ])
        let saves = await metadata.savedDrafts()
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.first?.url, oldURL)
        XCTAssertEqual(saves.first?.draft.artist, "Saved Artist")

        XCTAssertEqual(session.selectedFileURL, oldURL)
        XCTAssertEqual(session.loadedTag?.url, oldURL)
        XCTAssertEqual(session.draft?.artist, "Saved Artist")
        XCTAssertEqual(session.originalDraft?.artist, "Saved Artist")
        XCTAssertFalse(session.hasUnsavedTagChanges)
        XCTAssertTrue(session.hasUnsavedFilenameChange)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.filenameDraft?.proposedFilename, "Renamed.mp3")
        XCTAssertEqual(session.presentedError?.title, "Tags Saved, File Not Renamed")
        XCTAssertTrue(
            session.presentedError?.message.contains("Forced rename failure.") == true
        )
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
        URL(fileURLWithPath: "/tmp/TaggerFilenameTests/\(name)")
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

private actor FilenameTestRenamer: FileRenaming {
    struct ValidationCall: Equatable, Sendable {
        let source: URL
        let fileName: String
    }

    struct RenameCall: Equatable, Sendable {
        let source: URL
        let destination: URL
    }

    private let validationError: (any Error & Sendable)?
    private let renameError: (any Error & Sendable)?
    private var recordedValidationCalls: [ValidationCall] = []
    private var recordedRenameCalls: [RenameCall] = []

    init(
        validationError: (any Error & Sendable)? = nil,
        renameError: (any Error & Sendable)? = nil
    ) {
        self.validationError = validationError
        self.renameError = renameError
    }

    func validateRename(from source: URL, toFileName fileName: String) throws -> URL {
        recordedValidationCalls.append(.init(source: source, fileName: fileName))
        if let validationError {
            throw validationError
        }
        return source.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    func rename(from source: URL, to destination: URL) throws {
        recordedRenameCalls.append(.init(source: source, destination: destination))
        if let renameError {
            throw renameError
        }
    }

    func validateCalls() -> [ValidationCall] {
        recordedValidationCalls
    }

    func renameCalls() -> [RenameCall] {
        recordedRenameCalls
    }
}

private actor FilenameTestMetadataService: ID3MetadataServicing {
    struct SaveCall: Equatable, Sendable {
        let url: URL
        let draft: ID3TagDraft
    }

    private var tags: [URL: LoadedID3Tag]
    private var validations: [URL] = []
    private var saves: [SaveCall] = []

    init(tags: [URL: LoadedID3Tag]) {
        self.tags = tags
    }

    func load(from url: URL) throws -> LoadedID3Tag {
        guard let tag = tags[url] else {
            throw FilenameTestError.missingTag(url.lastPathComponent)
        }
        return tag
    }

    func validateUnchanged(_ loaded: LoadedID3Tag) throws {
        validations.append(loaded.url)
        guard tags[loaded.url] != nil else {
            throw FilenameTestError.missingTag(loaded.url.lastPathComponent)
        }
    }

    func save(_ loaded: LoadedID3Tag, draft: ID3TagDraft) throws -> LoadedID3Tag {
        saves.append(.init(url: loaded.url, draft: draft))
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

    func validatedURLs() -> [URL] {
        validations
    }

    func savedDrafts() -> [SaveCall] {
        saves
    }
}

private enum FilenameTestError: LocalizedError {
    case missingTag(String)

    var errorDescription: String? {
        switch self {
        case .missingTag(let filename):
            return "No fake tag exists for \(filename)."
        }
    }
}
