import AudioMarker
import Foundation
import XCTest
@testable import Tagger

final class LibrarySessionAutoTagTests: XCTestCase {
    @MainActor
    func testArtworkOnlyProposalWritesOnlyOnExplicitSaveAndPreservesMP3Bytes() async throws {
        for version: UInt8 in [3, 4] {
            let fixture = try makeTaggedFixture(version: version)
            defer { try? FileManager.default.removeItem(at: fixture.folder) }
            let candidate = musicBrainzCandidate()
            let autoTagger = AutoTagServiceStub(
                outcome: AutoTagSearchOutcome(candidates: [candidate], warningMessage: nil),
                proposal: AutoTagProposal(candidate: candidate, values: AutoTagValues(), artwork: artwork())
            )
            let session = LibrarySession(autoTaggingService: autoTagger)
            session.requestSelectFile(fixture.file)
            try await waitUntil { !session.isLoadingTag }
            let originalDraft = session.draft
            session.startAutoTagSearch()
            session.searchMusicBrainzTags()
            try await waitUntil { session.autoTagPhase == .choosing }
            session.resolveAutoTagCandidate(candidate)
            try await waitUntil { session.autoTagPhase == .reviewing }

            XCTAssertEqual(session.draft, originalDraft)
            XCTAssertTrue(session.autoTagReview?.selectedFields.isEmpty == true)
            XCTAssertTrue(session.autoTagReview?.isArtworkSelected == true)
            XCTAssertTrue(session.canApplyAutoTagReview)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.originalBytes)
            session.applyAutoTagReview()
            XCTAssertEqual(session.draft?.artworkData, artwork().data)
            XCTAssertEqual(session.originalDraft, originalDraft)
            XCTAssertTrue(session.isDirty)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.originalBytes)

            let didSave = await session.save()
            XCTAssertTrue(didSave, session.presentedError?.message ?? "Artwork save failed")
            XCTAssertFalse(session.isDirty)
            let reloaded = try await ID3MetadataService().load(from: fixture.file)
            XCTAssertEqual(reloaded.draft.artworkData, artwork().data)
            XCTAssertEqual(reloaded.draft.title, originalDraft?.title)
            let bytes = try Data(contentsOf: fixture.file)
            XCTAssertEqual(bytes[3], version)
            XCTAssertEqual(bytes.suffix(fixture.audio.count), fixture.audio)
            XCTAssertEqual(try unknownFramePayload(in: bytes, version: version), fixture.unknownPayload)
        }
    }

    @MainActor
    func testArtworkReplacementRequiresSelectionAndRevertPreservesOriginal() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Original.mp3")
        let original = ID3TagDraft(title: "Original Title", artworkData: Data([1, 2, 3]))
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: original)])
        let candidate = musicBrainzCandidate()
        let autoTagger = AutoTagServiceStub(
            outcome: AutoTagSearchOutcome(candidates: [candidate], warningMessage: nil),
            proposal: AutoTagProposal(candidate: candidate, values: AutoTagValues(), artwork: artwork())
        )
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitUntil { session.autoTagPhase == .choosing }
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        XCTAssertFalse(session.autoTagReview?.isArtworkSelected == true)
        XCTAssertFalse(session.canApplyAutoTagReview)
        session.setAutoTagArtwork(isSelected: true)
        XCTAssertTrue(session.canApplyAutoTagReview)
        session.setAutoTagArtwork(isSelected: false)
        XCTAssertFalse(session.canApplyAutoTagReview)
        XCTAssertEqual(session.draft, original)
        session.setAutoTagArtwork(isSelected: true)
        session.applyAutoTagReview()
        XCTAssertEqual(session.draft?.artworkData, artwork().data)
        XCTAssertTrue(session.isDirty)
        session.revert()
        XCTAssertEqual(session.draft, original)
        XCTAssertFalse(session.isDirty)
        let saves = await metadata.savedDrafts()
        XCTAssertTrue(saves.isEmpty)
    }

    @MainActor
    func testLateArtworkAfterCancellationOrSelectionChangeIsIgnored() async throws {
        for changeSelection in [false, true] {
            let first = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/First.mp3")
            let second = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Second.mp3")
            let metadata = AutoTagMetadataStub(tags: [
                first: loadedTag(url: first, draft: ID3TagDraft()),
                second: loadedTag(url: second, draft: ID3TagDraft()),
            ])
            let candidate = musicBrainzCandidate()
            let autoTagger = ControlledAutoTagServiceStub()
            let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
            session.requestSelectFile(first)
            try await waitUntil { !session.isLoadingTag }
            session.startAutoTagSearch()
            session.searchMusicBrainzTags()
            try await waitForService { await autoTagger.searchCount() == 1 }
            await autoTagger.finishSearch(0, candidates: [candidate])
            try await waitUntil { session.autoTagPhase == .choosing }
            session.resolveAutoTagCandidate(candidate)
            try await waitForService { await autoTagger.resolutionCount() == 1 }
            if changeSelection {
                session.requestSelectFile(second)
                try await waitUntil { !session.isLoadingTag && session.selectedFileURL == second }
            } else {
                session.cancelAutoTagging()
            }
            await autoTagger.finishResolution(0, artwork: artwork())
            try await waitForService { await autoTagger.returnedResolutionCount() == 1 }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(session.autoTagPhase, .idle)
            XCTAssertNil(session.autoTagReview)
            XCTAssertEqual(session.draft, ID3TagDraft())
            XCTAssertFalse(session.isDirty)
            let saves = await metadata.savedDrafts()
            XCTAssertTrue(saves.isEmpty)
        }
    }

    @MainActor
    func testApplyChangesOnlySelectedDraftFieldsAndPerformsNoIO() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/01 - Portishead - Roads.mp3")
        let original = ID3TagDraft(
            title: "",
            artist: "Manual Artist",
            genre: "Trip-Hop",
            comment: "Keep Comment",
            lyrics: "Keep Lyrics",
            artworkData: Data([0x01])
        )
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: original)])
        let candidate = musicBrainzCandidate()
        let proposal = AutoTagProposal(
            candidate: candidate,
            values: AutoTagValues(
                title: "Roads",
                artist: "Portishead",
                album: "Dummy",
                albumArtist: "Portishead",
                trackNumber: "1",
                discNumber: "1",
                year: "1994"
            )
        )
        let autoTagger = AutoTagServiceStub(
            outcome: AutoTagSearchOutcome(candidates: [candidate], warningMessage: nil),
            proposal: proposal
        )
        let session = LibrarySession(
            metadataService: metadata,
            autoTaggingService: autoTagger
        )

        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }
        session.draft?.composer = "Unsaved Composer"
        session.filenameDraft?.stem = "Unsaved File Name"
        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitUntil { session.autoTagPhase == .choosing }
        XCTAssertFalse(session.canSave)
        let savesAfterSearch = await metadata.savedDrafts()
        XCTAssertTrue(savesAfterSearch.isEmpty)
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        let savesAfterReview = await metadata.savedDrafts()
        XCTAssertTrue(savesAfterReview.isEmpty)

        XCTAssertFalse(session.autoTagReview?.selectedFields.contains(.artist) == true)
        XCTAssertTrue(session.autoTagReview?.selectedFields.contains(.title) == true)
        session.setAutoTagField(.artist, isSelected: true)
        session.applyAutoTagReview()

        XCTAssertEqual(session.draft?.title, "Roads")
        XCTAssertEqual(session.draft?.artist, "Portishead")
        XCTAssertEqual(session.draft?.album, "Dummy")
        XCTAssertEqual(session.draft?.genre, "Trip-Hop")
        XCTAssertEqual(session.draft?.composer, "Unsaved Composer")
        XCTAssertEqual(session.draft?.comment, "Keep Comment")
        XCTAssertEqual(session.draft?.lyrics, "Keep Lyrics")
        XCTAssertEqual(session.draft?.artworkData, Data([0x01]))
        XCTAssertEqual(session.filenameDraft?.proposedFilename, "Unsaved File Name.mp3")
        XCTAssertEqual(session.originalDraft, original)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.canSave)
        let savesAfterApply = await metadata.savedDrafts()
        XCTAssertTrue(savesAfterApply.isEmpty)

        session.revert()
        XCTAssertEqual(session.draft, original)
        XCTAssertEqual(session.filenameDraft?.proposedFilename, url.lastPathComponent)
        XCTAssertFalse(session.isDirty)
        let savesAfterRevert = await metadata.savedDrafts()
        XCTAssertTrue(savesAfterRevert.isEmpty)
    }

    @MainActor
    func testSelectionChangeCancelsAndIgnoresLateSearchResult() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/First.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Second.mp3")
        let metadata = AutoTagMetadataStub(tags: [
            firstURL: loadedTag(url: firstURL, draft: ID3TagDraft()),
            secondURL: loadedTag(url: secondURL, draft: ID3TagDraft()),
        ])
        let candidate = musicBrainzCandidate()
        let autoTagger = ControlledAutoTagServiceStub()
        let session = LibrarySession(
            metadataService: metadata,
            autoTaggingService: autoTagger
        )

        session.requestSelectFile(firstURL)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        XCTAssertEqual(session.autoTagPhase, .searching)
        try await waitForService { await autoTagger.searchCount() == 1 }

        session.requestSelectFile(secondURL)
        try await waitUntil { !session.isLoadingTag && session.selectedFileURL == secondURL }
        await autoTagger.finishSearch(0, candidates: [candidate])
        try await waitForService { await autoTagger.returnedSearchCount() == 1 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(session.autoTagPhase, .idle)
        XCTAssertFalse(session.isShowingAutoTagSheet)
        XCTAssertTrue(session.autoTagCandidates.isEmpty)
        XCTAssertEqual(session.selectedFileURL, secondURL)
    }

    @MainActor
    func testOpeningFindTagsShowsFilenameImmediatelyWithoutSearchingAndUsesEditedQuery() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/01 - Portishead - Roads.mp3")
        let original = ID3TagDraft(album: "Draft Album")
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: original)])
        let autoTagger = ControlledAutoTagServiceStub()
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }

        session.startAutoTagSearch()

        XCTAssertEqual(session.autoTagPhase, .choosing)
        XCTAssertEqual(session.autoTagCandidates.first?.source, .filename)
        XCTAssertEqual(session.autoTagCandidates.first?.preview.title, "Roads")
        XCTAssertEqual(session.autoTagSearchTitle, "Roads")
        XCTAssertEqual(session.autoTagSearchArtist, "Portishead")
        XCTAssertEqual(session.autoTagSearchAlbum, "Draft Album")
        let initialSearchCount = await autoTagger.searchCount()
        XCTAssertEqual(initialSearchCount, 0)
        XCTAssertEqual(session.draft, original)

        session.autoTagSearchTitle = "Edited Title"
        session.autoTagSearchArtist = "Edited Artist"
        session.autoTagSearchAlbum = "Edited Album"
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 1 }
        let request = await autoTagger.searchRequest(at: 0)
        XCTAssertEqual(request.searchSeed, MusicBrainzSearchSeed(
            title: "Edited Title", artist: "Edited Artist", album: "Edited Album"
        ))
        XCTAssertEqual(request.currentDraft, original)
        await autoTagger.finishSearch(0, candidates: [])
        try await waitUntil { !session.isAutoTagging }
        session.cancelAutoTagging()

        XCTAssertEqual(session.draft, original)
        XCTAssertFalse(session.isDirty)
        let saves = await metadata.savedDrafts()
        XCTAssertTrue(saves.isEmpty)
    }

    @MainActor
    func testCancellingReviewPreservesExistingEditsAndDoesNotWrite() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Original.mp3")
        let original = ID3TagDraft(title: "Original Title")
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: original)])
        let candidate = musicBrainzCandidate()
        let autoTagger = AutoTagServiceStub(
            outcome: AutoTagSearchOutcome(candidates: [candidate], warningMessage: nil),
            proposal: AutoTagProposal(candidate: candidate, values: candidate.preview)
        )
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }
        session.draft?.artist = "Unsaved Artist"
        session.filenameDraft?.stem = "Unsaved Rename"
        let editedDraft = session.draft
        let editedFilename = session.filenameDraft

        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitUntil { session.autoTagPhase == .choosing }
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        session.setAutoTagField(.title, isSelected: true)
        session.cancelAutoTagging()

        XCTAssertEqual(session.autoTagPhase, .idle)
        XCTAssertNil(session.autoTagReview)
        XCTAssertFalse(session.isShowingAutoTagSheet)
        XCTAssertEqual(session.draft, editedDraft)
        XCTAssertEqual(session.filenameDraft, editedFilename)
        XCTAssertTrue(session.isDirty)
        let saves = await metadata.savedDrafts()
        XCTAssertTrue(saves.isEmpty)
    }

    @MainActor
    func testRetryIgnoresSearchResultFromCancelledSheet() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Original.mp3")
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: ID3TagDraft())])
        let autoTagger = ControlledAutoTagServiceStub()
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }

        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 1 }
        session.cancelAutoTagging()
        session.startAutoTagSearch()
        session.autoTagSearchTitle = "New Query"
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 2 }
        let newCandidate = musicBrainzCandidate(id: "new-result", title: "New Result")
        await autoTagger.finishSearch(1, candidates: [newCandidate])
        try await waitUntil { session.autoTagPhase == .choosing }
        XCTAssertEqual(session.autoTagCandidates, [newCandidate])

        await autoTagger.finishSearch(0, candidates: [musicBrainzCandidate()])
        try await waitForService { await autoTagger.returnedSearchCount() == 2 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(session.autoTagPhase, .choosing)
        XCTAssertEqual(session.autoTagCandidates, [newCandidate])
        XCTAssertEqual(session.autoTagSearchTitle, "New Query")
        XCTAssertEqual(session.draft, ID3TagDraft())
        let saves = await metadata.savedDrafts()
        XCTAssertTrue(saves.isEmpty)
        session.cancelAutoTagging()
    }

    @MainActor
    func testCancelledResolutionCannotReplaceReviewAfterRetry() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Original.mp3")
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: ID3TagDraft())])
        let autoTagger = ControlledAutoTagServiceStub()
        let first = musicBrainzCandidate()
        let second = musicBrainzCandidate(id: "second", title: "Second Title")
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 1 }
        await autoTagger.finishSearch(0, candidates: [first, second])
        try await waitUntil { session.autoTagPhase == .choosing }

        session.resolveAutoTagCandidate(first)
        try await waitForService { await autoTagger.resolutionCount() == 1 }
        session.cancelAutoTagging()
        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 2 }
        await autoTagger.finishSearch(1, candidates: [second])
        try await waitUntil { session.autoTagPhase == .choosing }
        session.resolveAutoTagCandidate(second)
        try await waitForService { await autoTagger.resolutionCount() == 2 }
        await autoTagger.finishResolution(1)
        try await waitUntil { session.autoTagPhase == .reviewing }
        XCTAssertEqual(session.autoTagReview?.proposal.candidate, second)

        await autoTagger.finishResolution(0)
        try await waitForService { await autoTagger.returnedResolutionCount() == 2 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(session.autoTagReview?.proposal.candidate, second)
        XCTAssertEqual(session.draft, ID3TagDraft())
        let saves = await metadata.savedDrafts()
        XCTAssertTrue(saves.isEmpty)
        session.cancelAutoTagging()
    }

    @MainActor
    func testChoosingFilenameDuringSearchIgnoresLateRemoteCandidates() async throws {
        let url = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Portishead - Roads.mp3")
        let metadata = AutoTagMetadataStub(tags: [url: loadedTag(url: url, draft: ID3TagDraft())])
        let autoTagger = ControlledAutoTagServiceStub()
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(url)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        let localCandidate = try XCTUnwrap(session.autoTagCandidates.first)
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 1 }

        session.resolveAutoTagCandidate(localCandidate)
        try await waitForService { await autoTagger.resolutionCount() == 1 }
        await autoTagger.finishResolution(0)
        try await waitUntil { session.autoTagPhase == .reviewing }
        await autoTagger.finishSearch(0, candidates: [musicBrainzCandidate()])
        try await waitForService { await autoTagger.returnedSearchCount() == 1 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(session.autoTagPhase, .reviewing)
        XCTAssertEqual(session.autoTagReview?.proposal.candidate, localCandidate)
        XCTAssertEqual(session.draft, ID3TagDraft())
        let saves = await metadata.savedDrafts()
        XCTAssertTrue(saves.isEmpty)
        session.cancelAutoTagging()
    }

    @MainActor
    func testSelectionChangeIgnoresLateResolution() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/First.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Second.mp3")
        let secondDraft = ID3TagDraft(title: "Second File Title")
        let metadata = AutoTagMetadataStub(tags: [
            firstURL: loadedTag(url: firstURL, draft: ID3TagDraft()),
            secondURL: loadedTag(url: secondURL, draft: secondDraft),
        ])
        let candidate = musicBrainzCandidate()
        let autoTagger = ControlledAutoTagServiceStub()
        let session = LibrarySession(metadataService: metadata, autoTaggingService: autoTagger)
        session.requestSelectFile(firstURL)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        session.searchMusicBrainzTags()
        try await waitForService { await autoTagger.searchCount() == 1 }
        await autoTagger.finishSearch(0, candidates: [candidate])
        try await waitUntil { session.autoTagPhase == .choosing }
        session.resolveAutoTagCandidate(candidate)
        try await waitForService { await autoTagger.resolutionCount() == 1 }

        session.requestSelectFile(secondURL)
        try await waitUntil { !session.isLoadingTag && session.selectedFileURL == secondURL }
        await autoTagger.finishResolution(0)
        try await waitForService { await autoTagger.returnedResolutionCount() == 1 }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(session.autoTagPhase, .idle)
        XCTAssertFalse(session.isShowingAutoTagSheet)
        XCTAssertNil(session.autoTagReview)
        XCTAssertEqual(session.draft, secondDraft)
        XCTAssertFalse(session.isDirty)
    }

    @MainActor
    func testAppliedSuggestionsParticipateInUnsavedNavigationGuard() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/First.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/TaggerAutoTagTests/Second.mp3")
        let metadata = AutoTagMetadataStub(tags: [
            firstURL: loadedTag(url: firstURL, draft: ID3TagDraft()),
            secondURL: loadedTag(url: secondURL, draft: ID3TagDraft()),
        ])
        let session = LibrarySession(metadataService: metadata)
        session.requestSelectFile(firstURL)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        let candidate = try XCTUnwrap(session.autoTagCandidates.first)
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        session.applyAutoTagReview()

        session.requestSelectFile(secondURL)

        XCTAssertTrue(session.isShowingUnsavedChangesAlert)
        XCTAssertEqual(session.selectedFileURL, firstURL)
        XCTAssertEqual(session.draft?.title, "First")
        let savesBeforeDiscard = await metadata.savedDrafts()
        XCTAssertTrue(savesBeforeDiscard.isEmpty)
        session.discardAndContinuePendingNavigation()
        try await waitUntil { !session.isLoadingTag && session.selectedFileURL == secondURL }
        XCTAssertFalse(session.isDirty)
        let savesAfterDiscard = await metadata.savedDrafts()
        XCTAssertTrue(savesAfterDiscard.isEmpty)
    }

    @MainActor
    func testExplicitSaveAfterApplyingSuggestionsPreservesID3v23AudioAndUnknownFrame() async throws {
        try await assertExplicitSavePreservesFile(version: 3)
    }

    @MainActor
    func testExplicitSaveAfterApplyingSuggestionsPreservesID3v24AudioAndUnknownFrame() async throws {
        try await assertExplicitSavePreservesFile(version: 4)
    }

    @MainActor
    func testExternalTagChangeRejectsSaveAndRetainsAppliedDraft() async throws {
        let fixture = try makeTaggedFixture(version: 4)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let session = LibrarySession()
        session.requestSelectFile(fixture.file)
        try await waitUntil { !session.isLoadingTag }
        let modificationDate = try XCTUnwrap(session.loadedTag?.snapshot.modificationDate)
        session.startAutoTagSearch()
        let candidate = try XCTUnwrap(session.autoTagCandidates.first)
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        session.setAutoTagField(.title, isSelected: true)
        session.applyAutoTagReview()
        let appliedDraft = session.draft

        var externallyChanged = fixture.originalBytes
        let titleRange = try XCTUnwrap(externallyChanged.range(of: Data("Original Title".utf8)))
        externallyChanged[titleRange.lowerBound] = 0x58
        try externallyChanged.write(to: fixture.file)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate], ofItemAtPath: fixture.file.path
        )
        let didSave = await session.save()

        XCTAssertFalse(didSave)
        XCTAssertEqual(session.draft, appliedDraft)
        XCTAssertEqual(session.originalDraft?.title, "Original Title")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.presentedError?.message, ID3TagServiceError.fileChangedExternally.localizedDescription)
        XCTAssertEqual(try Data(contentsOf: fixture.file), externallyChanged)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for LibrarySession state to settle")
    }

    @MainActor
    private func waitForService(
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the controlled auto-tag service")
    }

    @MainActor
    private func assertExplicitSavePreservesFile(version: UInt8) async throws {
        let fixture = try makeTaggedFixture(version: version)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let session = LibrarySession()
        session.requestSelectFile(fixture.file)
        try await waitUntil { !session.isLoadingTag }
        XCTAssertEqual(session.draft?.title, "Original Title")

        session.startAutoTagSearch()
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.originalBytes)
        let candidate = try XCTUnwrap(session.autoTagCandidates.first)
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.originalBytes)
        XCTAssertEqual(session.draft?.title, "Original Title")
        XCTAssertFalse(session.autoTagReview?.selectedFields.contains(.title) == true)
        session.setAutoTagField(.title, isSelected: true)
        session.applyAutoTagReview()
        XCTAssertEqual(session.draft?.title, "Roads")
        XCTAssertEqual(session.originalDraft?.title, "Original Title")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.originalBytes)

        let didSave = await session.save()

        XCTAssertTrue(didSave)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.draft?.title, "Roads")
        XCTAssertEqual(session.draft?.artist, "Portishead")
        XCTAssertEqual(session.draft?.trackNumber, "1")
        XCTAssertEqual(session.originalDraft, session.draft)
        let bytes = try Data(contentsOf: fixture.file)
        XCTAssertEqual(bytes[3], version)
        XCTAssertEqual(bytes.suffix(fixture.audio.count), fixture.audio)
        let tagEnd = 10 + bytes[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        XCTAssertEqual(bytes.suffix(from: tagEnd), fixture.audio)
        XCTAssertEqual(try unknownFramePayload(in: bytes, version: version), fixture.unknownPayload)
    }

    // Every file is generated in a unique disposable directory, never a music library.
    private func makeTaggedFixture(version: UInt8) throws -> (
        folder: URL, file: URL, originalBytes: Data, audio: Data, unknownPayload: Data
    ) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("01 - Portishead - Roads.mp3")
        let unknownPayload = Data((0..<130).map(UInt8.init))
        let frames = makeFrame(id: "TIT2", payload: Data([0]) + Data("Original Title".utf8), version: version)
            + makeFrame(id: "XZZZ", payload: unknownPayload, version: version)
        var tag = Data([0x49, 0x44, 0x33, version, 0, 0])
        tag.append(contentsOf: encodedSize(frames.count, syncsafe: true))
        tag.append(frames)
        let audio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 2_048)
        let originalBytes = tag + audio
        try originalBytes.write(to: file)
        return (folder, file, originalBytes, audio, unknownPayload)
    }

    private func makeFrame(id: String, payload: Data, version: UInt8) -> Data {
        Data(id.utf8)
            + Data(encodedSize(payload.count, syncsafe: version == 4))
            + Data([0, 0])
            + payload
    }

    private func encodedSize(_ size: Int, syncsafe: Bool) -> [UInt8] {
        let width = syncsafe ? 7 : 8
        let mask = syncsafe ? 0x7F : 0xFF
        return (0..<4).reversed().map { UInt8((size >> ($0 * width)) & mask) }
    }

    private func unknownFramePayload(in data: Data, version: UInt8) throws -> Data? {
        let bytes = [UInt8](data)
        let tagEnd = 10 + bytes[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        var offset = 10
        while offset + 10 <= tagEnd, bytes[offset] != 0 {
            let size = bytes[(offset + 4)..<(offset + 8)].reduce(0) {
                ($0 << (version == 4 ? 7 : 8)) | Int($1)
            }
            let payloadStart = offset + 10
            let payloadEnd = payloadStart + size
            guard payloadEnd <= tagEnd, tagEnd <= bytes.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if String(bytes: bytes[offset..<(offset + 4)], encoding: .utf8) == "XZZZ" {
                return Data(bytes[payloadStart..<payloadEnd])
            }
            offset = payloadEnd
        }
        return nil
    }

    private func musicBrainzCandidate(
        id: String = "musicbrainz:test", title: String = "Roads"
    ) -> AutoTagCandidate {
        let values = AutoTagValues(
            title: title,
            artist: "Portishead",
            album: "Dummy",
            albumArtist: "Portishead",
            trackNumber: "1",
            discNumber: "1",
            year: "1994"
        )
        return AutoTagCandidate(
            id: id,
            source: .musicBrainz,
            title: title,
            subtitle: "Portishead • Dummy",
            matchScore: 100,
            reference: .musicBrainz(
                recordingID: "4e43d873-7b8a-4b95-97e6-4f692b1a0c75",
                releaseID: "f4cf6b7b-5d14-4f30-8a83-50a70591198f"
            ),
            preview: values
        )
    }

    private func artwork() -> AutoTagArtwork {
        AutoTagArtwork(
            data: Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!,
            sourceURL: URL(string: "https://coverartarchive.org/release/f4cf6b7b-5d14-4f30-8a83-50a70591198f/front-1200")!
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

private actor AutoTagServiceStub: AutoTaggingServicing {
    let outcome: AutoTagSearchOutcome
    let proposal: AutoTagProposal

    init(outcome: AutoTagSearchOutcome, proposal: AutoTagProposal) {
        self.outcome = outcome
        self.proposal = proposal
    }

    func search(_ request: AutoTagSearchRequest) async throws -> AutoTagSearchOutcome {
        outcome
    }

    func resolve(
        _ candidate: AutoTagCandidate,
        for request: AutoTagSearchRequest
    ) async throws -> AutoTagProposal {
        proposal
    }
}

// Deliberately ignores task cancellation so tests exercise session generation checks.
private actor ControlledAutoTagServiceStub: AutoTaggingServicing {
    private var requests: [AutoTagSearchRequest] = []
    private var resolutions: [AutoTagCandidate] = []
    private var searches: [Int: CheckedContinuation<AutoTagSearchOutcome, Never>] = [:]
    private var proposals: [Int: CheckedContinuation<AutoTagProposal, Never>] = [:]
    private var returnedSearches = 0
    private var returnedResolutions = 0

    func search(_ request: AutoTagSearchRequest) async throws -> AutoTagSearchOutcome {
        let index = requests.count
        requests.append(request)
        let outcome = await withCheckedContinuation { searches[index] = $0 }
        returnedSearches += 1
        return outcome
    }

    func resolve(
        _ candidate: AutoTagCandidate,
        for request: AutoTagSearchRequest
    ) async throws -> AutoTagProposal {
        let index = resolutions.count
        resolutions.append(candidate)
        let proposal = await withCheckedContinuation { proposals[index] = $0 }
        returnedResolutions += 1
        return proposal
    }

    func searchCount() -> Int { requests.count }
    func resolutionCount() -> Int { resolutions.count }
    func returnedSearchCount() -> Int { returnedSearches }
    func returnedResolutionCount() -> Int { returnedResolutions }
    func searchRequest(at index: Int) -> AutoTagSearchRequest { requests[index] }

    func finishSearch(_ index: Int, candidates: [AutoTagCandidate]) {
        searches.removeValue(forKey: index)?.resume(returning: AutoTagSearchOutcome(
            candidates: candidates, warningMessage: nil
        ))
    }

    func finishResolution(_ index: Int, artwork: AutoTagArtwork? = nil) {
        let candidate = resolutions[index]
        proposals.removeValue(forKey: index)?.resume(returning: AutoTagProposal(
            candidate: candidate, values: candidate.preview, artwork: artwork
        ))
    }
}

private actor AutoTagMetadataStub: ID3MetadataServicing {
    private var tags: [URL: LoadedID3Tag]
    private var saves: [ID3TagDraft] = []

    init(tags: [URL: LoadedID3Tag]) {
        self.tags = tags
    }

    func load(from url: URL) async throws -> LoadedID3Tag {
        guard let tag = tags[url] else { throw URLError(.fileDoesNotExist) }
        return tag
    }

    func validateUnchanged(_ loaded: LoadedID3Tag) async throws {}

    func save(_ loaded: LoadedID3Tag, draft: ID3TagDraft) async throws -> LoadedID3Tag {
        saves.append(draft)
        return loaded
    }

    func savedDrafts() -> [ID3TagDraft] {
        saves
    }
}
