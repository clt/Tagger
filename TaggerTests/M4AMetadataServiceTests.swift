import Foundation
import XCTest
@testable import Tagger

final class M4AMetadataServiceTests: XCTestCase {
    func testLoadsAllCommonFieldsAndArtworkWithoutChangingTheFile() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let loaded = try await AudioMetadataService().load(from: fixture.file)

        XCTAssertEqual(loaded.draft, M4ATestFixture.originalDraft)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
    }

    func testUppercaseM4AExtensionAndUnchangedSavePreserveExactBytes() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let uppercaseFile = fixture.folder.appendingPathComponent("Uppercase.M4A")
        try fixture.original.write(to: uppercaseFile)
        let service = AudioMetadataService()
        let loaded = try await service.load(from: uppercaseFile)
        let saved = try await service.save(loaded, draft: loaded.draft)

        XCTAssertEqual(saved.draft, M4ATestFixture.originalDraft)
        XCTAssertEqual(try Data(contentsOf: uppercaseFile), fixture.original)
    }

    func testAddsAndClearsAllSupportedMetadataOnAACAndALAC() async throws {
        for codec in ["mp4a", "alac"] {
            let fixture = try M4ATestFixture(codec: codec, metadata: nil)
            defer { fixture.remove() }
            let service = M4AMetadataService()
            let loaded = try await service.load(from: fixture.file)
            XCTAssertEqual(loaded.draft, ID3TagDraft())

            let saved = try await service.save(loaded, draft: M4ATestFixture.originalDraft)
            XCTAssertEqual(saved.draft, M4ATestFixture.originalDraft)
            try assertMediaPreserved(in: Data(contentsOf: fixture.file), fixture: fixture)

            let cleared = try await service.save(saved, draft: ID3TagDraft())
            XCTAssertEqual(cleared.draft, ID3TagDraft())
            let bytes = try Data(contentsOf: fixture.file)
            XCTAssertNil(try M4ATestAtom.find(["moov", "udta", "meta", "ilst", "covr"], in: bytes))
            try assertMediaPreserved(in: bytes, fixture: fixture)
        }
    }

    func testMetadataGrowthAndShrinkPreserveChunkOffsetsForBothMovieLayouts() async throws {
        for movieFirst in [true, false] {
            for wideOffsets in [false, true] {
                let fixture = try M4ATestFixture(
                    movieFirst: movieFirst,
                    wideOffsets: wideOffsets,
                    metadata: M4ATestFixture.taggedItems
                )
                defer { fixture.remove() }
                let service = M4AMetadataService()
                let loaded = try await service.load(from: fixture.file)
                var draft = loaded.draft
                draft.title = String(repeating: "A much longer title – ", count: 100) + "End"
                draft.comment = "Updated comment"
                let saved = try await service.save(loaded, draft: draft)
                XCTAssertEqual(saved.draft, draft)
                let grown = try Data(contentsOf: fixture.file)
                try assertMediaPreserved(in: grown, fixture: fixture)
                try assertUnknownMetadataPreserved(in: grown)

                draft.title = "A"
                draft.comment = ""
                let shrunk = try await service.save(saved, draft: draft)
                XCTAssertEqual(shrunk.draft, draft)
                let bytes = try Data(contentsOf: fixture.file)
                try assertMediaPreserved(in: bytes, fixture: fixture)
                try assertUnknownMetadataPreserved(in: bytes)
            }
        }
    }

    func testUneditedFullDateAndNumberTotalsSurviveOtherEdits() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        XCTAssertEqual(loaded.draft.year, "2020")
        var draft = loaded.draft
        draft.artist = "A different artist"
        _ = try await service.save(loaded, draft: draft)
        let bytes = try Data(contentsOf: fixture.file)

        for key in ["©day", "trkn", "disk"] {
            XCTAssertEqual(
                try M4ATestAtom.find(["moov", "udta", "meta", "ilst", key], in: bytes)?.raw,
                try M4ATestAtom.find(["moov", "udta", "meta", "ilst", key], in: fixture.original)?.raw
            )
        }
    }

    func testChangingTrackAndDiscKeepsTheirExistingTotals() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        var draft = loaded.draft
        draft.trackNumber = "7"
        draft.discNumber = "2"
        let saved = try await service.save(loaded, draft: draft)
        XCTAssertEqual(saved.draft.trackNumber, "7")
        XCTAssertEqual(saved.draft.discNumber, "2")
        let bytes = try Data(contentsOf: fixture.file)
        let track = try metadataValue("trkn", in: bytes)
        let disc = try metadataValue("disk", in: bytes)
        XCTAssertEqual(M4ATestFixture.integer(track[2..<4]), 7)
        XCTAssertEqual(M4ATestFixture.integer(track[4..<6]), 12)
        XCTAssertEqual(M4ATestFixture.integer(disc[2..<4]), 2)
        XCTAssertEqual(M4ATestFixture.integer(disc[4..<6]), 3)
    }

    func testClearingTrackAndDiscPreservesTotalsAndReservedBytes() async throws {
        for hasTotals in [true, false] {
            var track = Data([0x12, 0x34, 0, 3, 0, hasTotals ? 12 : 0, 0x56, 0x78])
            var disc = Data([0xAB, 0xCD, 0, 1, 0, hasTotals ? 3 : 0])
            let fixture = try M4ATestFixture(metadata:
                M4ATestFixture.item("trkn", value: track)
                + M4ATestFixture.item("disk", value: disc) + M4ATestFixture.unknownItem
            )
            defer { fixture.remove() }
            let service = M4AMetadataService()
            let loaded = try await service.load(from: fixture.file)
            let cleared = try await service.save(loaded, draft: ID3TagDraft())
            XCTAssertEqual(cleared.draft, ID3TagDraft())
            track[3] = 0
            disc[3] = 0
            let bytes = try Data(contentsOf: fixture.file)
            XCTAssertEqual(try metadataValue("trkn", in: bytes), track)
            XCTAssertEqual(try metadataValue("disk", in: bytes), disc)
            try assertMediaPreserved(in: bytes, fixture: fixture)
            try assertUnknownMetadataPreserved(in: bytes)

            // A subsequent edit must also retain the information hidden from the draft.
            let reloaded = try await service.load(from: fixture.file)
            XCTAssertEqual(reloaded.draft, ID3TagDraft())
            let replacement = ID3TagDraft(trackNumber: "7", discNumber: "2")
            let saved = try await service.save(reloaded, draft: replacement)
            XCTAssertEqual(saved.draft, replacement)
            track[3] = 7
            disc[3] = 2
            let updatedBytes = try Data(contentsOf: fixture.file)
            XCTAssertEqual(try metadataValue("trkn", in: updatedBytes), track)
            XCTAssertEqual(try metadataValue("disk", in: updatedBytes), disc)
            try assertMediaPreserved(in: updatedBytes, fixture: fixture)
            try assertUnknownMetadataPreserved(in: updatedBytes)
        }
    }

    func testClearingTrackAndDiscWithoutOtherInformationRemovesTheirAtoms() async throws {
        let fixture = try M4ATestFixture(metadata:
            M4ATestFixture.item("trkn", value: Data([0, 0, 0, 3, 0, 0, 0, 0]))
            + M4ATestFixture.item("disk", value: Data([0, 0, 0, 1, 0, 0]))
            + M4ATestFixture.unknownItem
        )
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        let cleared = try await service.save(loaded, draft: ID3TagDraft())
        XCTAssertEqual(cleared.draft, ID3TagDraft())
        let bytes = try Data(contentsOf: fixture.file)
        for key in ["trkn", "disk"] {
            XCTAssertNil(try M4ATestAtom.find(["moov", "udta", "meta", "ilst", key], in: bytes))
        }
        try assertMediaPreserved(in: bytes, fixture: fixture)
        try assertUnknownMetadataPreserved(in: bytes)
    }

    func testReplacingArtworkPreservesAudioAndRemovingItRemovesTheCoverAtom() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        var draft = loaded.draft
        draft.artworkData = M4ATestFixture.secondPNG
        let saved = try await service.save(loaded, draft: draft)
        XCTAssertEqual(saved.draft.artworkData, M4ATestFixture.secondPNG)
        draft.artworkData = nil
        let cleared = try await service.save(saved, draft: draft)
        XCTAssertNil(cleared.draft.artworkData)
        let bytes = try Data(contentsOf: fixture.file)
        XCTAssertNil(try M4ATestAtom.find(["moov", "udta", "meta", "ilst", "covr"], in: bytes))
        try assertMediaPreserved(in: bytes, fixture: fixture)
    }

    func testRefusesSameSizeExternalMetadataAndAudioEditsWithRestoredModificationDate() async throws {
        for editAudio in [false, true] {
            let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
            defer { fixture.remove() }
            let service = M4AMetadataService()
            let loaded = try await service.load(from: fixture.file)
            let oldDate = try XCTUnwrap(loaded.snapshot.modificationDate)
            var externallyChanged = fixture.original
            let range = try XCTUnwrap(externallyChanged.range(of:
                editAudio ? fixture.audio[0] : Data("Original Title".utf8)
            ))
            externallyChanged[range.lowerBound] ^= 1
            try externallyChanged.write(to: fixture.file)
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate], ofItemAtPath: fixture.file.path
            )
            var draft = loaded.draft
            draft.title = "Should not be written"

            do {
                _ = try await service.save(loaded, draft: draft)
                XCTFail("An external \(editAudio ? "audio" : "metadata") edit must reject Save")
            } catch {
                XCTAssertEqual(try Data(contentsOf: fixture.file), externallyChanged)
            }
        }
    }

    func testRejectsMalformedAndUnsupportedContainersWithoutChangingBytes() async throws {
        let supported = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { supported.remove() }
        let unsupportedCodec = try M4ATestFixture(codec: "Opus")
        defer { unsupportedCodec.remove() }
        let protectedAudio = try M4ATestFixture(codec: "enca")
        defer { protectedAudio.remove() }
        let video = try M4ATestFixture(handler: "vide")
        defer { video.remove() }
        let externalData = try M4ATestFixture(selfContained: false)
        defer { externalData.remove() }
        let sizeTable = try XCTUnwrap(M4ATestAtom.find(
            ["moov", "trak", "mdia", "minf", "stbl", "stsz"], in: supported.original
        ))
        let sizeRange = try XCTUnwrap(supported.original.range(of: sizeTable.raw))
        var overflowingSample = supported.original
        overflowingSample.replaceSubrange(
            (sizeRange.lowerBound + 20)..<(sizeRange.lowerBound + 24),
            with: M4ATestFixture.word(supported.audio[0].count + 1)
        )
        var missingSizes = supported.original
        missingSizes.replaceSubrange(
            (sizeRange.lowerBound + 4)..<(sizeRange.lowerBound + 8), with: Data("free".utf8)
        )
        let cases: [(String, Data)] = [
            ("truncated", Data(supported.original.dropLast())),
            ("invalid box size", M4ATestFixture.word(4) + Data("ftyp".utf8)),
            ("missing movie", M4ATestFixture.box("ftyp", Data("M4A ".utf8) + M4ATestFixture.word(0))),
            ("unsupported codec", unsupportedCodec.original),
            ("protected audio", protectedAudio.original),
            ("video track", video.original),
            ("external data reference", externalData.original),
            ("fragmented movie", supported.original + M4ATestFixture.box("moof", Data())),
            ("sample extends past media", overflowingSample),
            ("missing sample size table", missingSizes),
        ]
        let service = M4AMetadataService()
        for (name, bytes) in cases {
            let file = supported.folder.appendingPathComponent(name + ".m4a")
            try bytes.write(to: file)
            do {
                _ = try await service.load(from: file)
                XCTFail("Expected \(name) to be rejected")
            } catch {
                XCTAssertEqual(try Data(contentsOf: file), bytes, name)
            }
        }
    }

    func testInvalidNumericDraftDoesNotWrite() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        for number in ["-1", "65536", "not a number"] {
            var draft = loaded.draft
            draft.trackNumber = number
            do {
                _ = try await service.save(loaded, draft: draft)
                XCTFail("Expected invalid or out-of-range M4A track number to be rejected")
            } catch {
                XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
            }
        }
    }

    func testSymlinkCannotBeUsedToWriteAnM4AFile() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        let link = fixture.folder.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        var draft = loaded.draft
        draft.title = "Should not be written"
        do {
            _ = try await service.save(loaded.relocated(to: link), draft: draft)
            XCTFail("Saving through a symbolic link must be rejected")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), fixture.file.path)
        }
    }

    func testIdenticalByteReplacementWithRestoredDateStillRejectsStaleSave() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        let oldDate = try XCTUnwrap(loaded.snapshot.modificationDate)
        let oldAttributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        try fixture.original.write(to: fixture.file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fixture.file.path)
        let newAttributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        XCTAssertNotEqual(oldAttributes[.systemFileNumber] as? NSNumber,
                          newAttributes[.systemFileNumber] as? NSNumber)
        var draft = loaded.draft
        draft.title = "Should not be written"

        do {
            _ = try await service.save(loaded, draft: draft)
            XCTFail("A replacement inode must reject a stale Save even when bytes and dates match")
        } catch let error as ID3TagServiceError {
            XCTAssertEqual(error, .fileChangedExternally)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
    }

    func testInvalidArtworkDoesNotChangeTheFile() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let service = M4AMetadataService()
        let loaded = try await service.load(from: fixture.file)
        var draft = loaded.draft
        draft.artworkData = Data("This is not an image".utf8)
        do {
            _ = try await service.save(loaded, draft: draft)
            XCTFail("Invalid artwork must be rejected before any write")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
        }
    }

    @MainActor
    func testMixedMP3AndM4ABatchSaveOnlyAppliesEnabledFieldAndPreservesMediaAndNames() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let mp3 = fixture.folder.appendingPathComponent("02 - MP3 Fixture.mp3")
        let mp3Audio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 2_048)
        try mp3Audio.write(to: mp3)
        let metadata = AudioMetadataService()
        let untagged = try await metadata.load(from: mp3)
        let mp3Draft = ID3TagDraft(title: "MP3 title", artist: "MP3 artist", album: "MP3 album",
                                   genre: "Rock", comment: "Keep this comment", artworkData: M4ATestFixture.tinyPNG)
        _ = try await metadata.save(untagged, draft: mp3Draft)
        let originalMP3 = try Data(contentsOf: mp3)
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).sorted()
        let session = LibrarySession(metadataService: metadata)
        session.entries = [
            DirectoryEntry(url: fixture.file, name: fixture.file.lastPathComponent,
                           kind: .m4a, fileSize: fixture.original.count),
            DirectoryEntry(url: mp3, name: mp3.lastPathComponent,
                           kind: .mp3, fileSize: originalMP3.count),
        ]
        session.requestSelectEntries([mp3, fixture.file])
        try await waitUntil { !session.isLoadingTag }
        XCTAssertEqual(session.selectedFileURLs, [fixture.file, mp3])
        session.batchDraft?.title.text = "Do not apply this title"
        session.batchDraft?.title.isApplied = false
        session.batchDraft?.genre.text = "Ambient"
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
        XCTAssertEqual(try Data(contentsOf: mp3), originalMP3)

        let didSave = await session.save()
        XCTAssertTrue(didSave, session.presentedError?.message ?? "Batch Save failed")
        XCTAssertFalse(session.isDirty)
        var expectedMP3 = mp3Draft
        expectedMP3.genre = "Ambient"
        var expectedM4A = M4ATestFixture.originalDraft
        expectedM4A.genre = "Ambient"
        let savedMP3 = try await metadata.load(from: mp3)
        let savedM4A = try await metadata.load(from: fixture.file)
        XCTAssertEqual(savedMP3.draft, expectedMP3)
        XCTAssertEqual(savedM4A.draft, expectedM4A)
        XCTAssertEqual(try Data(contentsOf: mp3).suffix(mp3Audio.count), mp3Audio)
        let bytes = try Data(contentsOf: fixture.file)
        try assertMediaPreserved(in: bytes, fixture: fixture)
        try assertUnknownMetadataPreserved(in: bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).sorted(), originalNames)
    }

    @MainActor
    func testM4AAutoTagReviewOnlyChangesDraftUntilExplicitSave() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let session = LibrarySession(metadataService: AudioMetadataService())
        session.requestSelectFile(fixture.file)
        try await waitUntil { !session.isLoadingTag }
        XCTAssertEqual(session.draft?.title, "Original Title")
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)

        session.startAutoTagSearch()
        let candidate = try XCTUnwrap(session.autoTagCandidates.first)
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)
        session.setAutoTagField(.title, isSelected: true)
        session.setAutoTagField(.artist, isSelected: true)
        session.setAutoTagField(.trackNumber, isSelected: true)
        session.applyAutoTagReview()
        XCTAssertEqual(session.draft?.title, "Roads")
        XCTAssertEqual(session.draft?.artist, "Portishead")
        XCTAssertEqual(session.draft?.trackNumber, "1")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)

        let didSave = await session.save()
        XCTAssertTrue(didSave, session.presentedError?.message ?? "Save failed")
        XCTAssertFalse(session.isDirty)
        let reloaded = try await M4AMetadataService().load(from: fixture.file)
        XCTAssertEqual(reloaded.draft, session.draft)
        XCTAssertEqual(reloaded.draft.title, "Roads")
        let written = try Data(contentsOf: fixture.file)
        try assertMediaPreserved(in: written, fixture: fixture)
        try assertUnknownMetadataPreserved(in: written)
    }

    @MainActor
    func testM4AArtworkSuggestionStaysInDraftAndSurvivesSaveFailure() async throws {
        for externalChange in [false, true] {
            let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
            defer { fixture.remove() }
            let autoTagger = M4AArtworkSuggestionStub()
            let session = LibrarySession(
                metadataService: AudioMetadataService(), autoTaggingService: autoTagger
            )
            session.requestSelectFile(fixture.file)
            try await waitUntil { !session.isLoadingTag }
            session.startAutoTagSearch()
            session.searchMusicBrainzTags()
            try await waitUntil { session.autoTagPhase == .choosing }
            session.resolveAutoTagCandidate(autoTagger.candidate)
            try await waitUntil { session.autoTagPhase == .reviewing }
            XCTAssertEqual(session.draft?.artworkData, M4ATestFixture.tinyPNG)
            XCTAssertFalse(session.autoTagReview?.isArtworkSelected == true)
            XCTAssertFalse(session.canApplyAutoTagReview)
            session.setAutoTagArtwork(isSelected: true)
            XCTAssertTrue(session.canApplyAutoTagReview)
            session.applyAutoTagReview()
            XCTAssertEqual(session.draft?.artworkData, M4ATestFixture.secondPNG)
            XCTAssertTrue(session.isDirty)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.original)

            var expected = M4ATestFixture.originalDraft
            expected.artworkData = M4ATestFixture.secondPNG
            if externalChange {
                let changed = fixture.original + M4ATestFixture.box("free", Data([1, 2, 3]))
                try changed.write(to: fixture.file)
                let didSave = await session.save()
                XCTAssertFalse(didSave)
                XCTAssertNotNil(session.presentedError)
                XCTAssertEqual(session.draft, expected)
                XCTAssertTrue(session.isDirty)
                XCTAssertEqual(try Data(contentsOf: fixture.file), changed)
            } else {
                let didSave = await session.save()
                XCTAssertTrue(didSave, session.presentedError?.message ?? "Artwork save failed")
                XCTAssertFalse(session.isDirty)
                let reloaded = try await M4AMetadataService().load(from: fixture.file)
                XCTAssertEqual(reloaded.draft, expected)
                let bytes = try Data(contentsOf: fixture.file)
                try assertMediaPreserved(in: bytes, fixture: fixture)
                try assertUnknownMetadataPreserved(in: bytes)
            }
        }
    }

    @MainActor
    func testFailedM4ASaveRetainsAppliedAutoTagDraft() async throws {
        let fixture = try M4ATestFixture(metadata: M4ATestFixture.taggedItems)
        defer { fixture.remove() }
        let session = LibrarySession(metadataService: AudioMetadataService())
        session.requestSelectFile(fixture.file)
        try await waitUntil { !session.isLoadingTag }
        session.startAutoTagSearch()
        let candidate = try XCTUnwrap(session.autoTagCandidates.first)
        session.resolveAutoTagCandidate(candidate)
        try await waitUntil { session.autoTagPhase == .reviewing }
        session.setAutoTagField(.title, isSelected: true)
        session.applyAutoTagReview()
        let applied = session.draft
        let changed = fixture.original + M4ATestFixture.box("free", Data([1, 2, 3]))
        try changed.write(to: fixture.file)

        let didSave = await session.save()
        XCTAssertFalse(didSave)
        XCTAssertNotNil(session.presentedError)
        XCTAssertEqual(session.draft, applied)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), changed)
    }

    @MainActor
    private func waitUntil(condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for LibrarySession state")
        throw CocoaError(.fileReadUnknown)
    }

    private func assertMediaPreserved(
        in bytes: Data, fixture: M4ATestFixture,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let topLevel = try M4ATestAtom.parse(bytes)
        let media = topLevel.filter { $0.type == "mdat" }
        XCTAssertEqual(media.map(\.payload), fixture.audio, file: file, line: line)
        XCTAssertEqual(topLevel.first { $0.type == "free" }?.raw,
                       M4ATestFixture.unrelatedBox, file: file, line: line)
        let type = fixture.wideOffsets ? "co64" : "stco"
        let offsets = try XCTUnwrap(M4ATestAtom.find(
            ["moov", "trak", "mdia", "minf", "stbl", type], in: bytes
        ), file: file, line: line)
        XCTAssertEqual(M4ATestFixture.integer(offsets.payload[4..<8]), media.count, file: file, line: line)
        let width = fixture.wideOffsets ? 8 : 4
        for (index, atom) in media.enumerated() {
            let start = 8 + index * width
            let offset = M4ATestFixture.integer(offsets.payload[start..<(start + width)])
            XCTAssertEqual(offset, atom.start + 8, file: file, line: line)
            XCTAssertEqual(Data(bytes[offset..<(offset + fixture.audio[index].count)]),
                           fixture.audio[index], file: file, line: line)
        }
    }

    private func assertUnknownMetadataPreserved(in bytes: Data) throws {
        XCTAssertEqual(
            try M4ATestAtom.find(["moov", "udta", "meta", "ilst", "----"], in: bytes)?.raw,
            M4ATestFixture.unknownItem
        )
        XCTAssertEqual(
            try M4ATestAtom.find(["moov", "udta", "uuid"], in: bytes)?.raw,
            M4ATestFixture.unknownUserData
        )
    }

    private func metadataValue(_ key: String, in bytes: Data) throws -> Data {
        let atom = try XCTUnwrap(M4ATestAtom.find(
            ["moov", "udta", "meta", "ilst", key, "data"], in: bytes
        ))
        return Data(atom.payload.dropFirst(8))
    }
}

private struct M4AArtworkSuggestionStub: AutoTaggingServicing {
    let candidate = AutoTagCandidate(
        id: "cover", source: .musicBrainz, title: "Original Title", subtitle: "Original Album",
        matchScore: 100,
        reference: .musicBrainz(
            recordingID: "4e43d873-7b8a-4b95-97e6-4f692b1a0c75",
            releaseID: "f4cf6b7b-5d14-4f30-8a83-50a70591198f"
        ),
        preview: AutoTagValues()
    )

    func search(_ request: AutoTagSearchRequest) async throws -> AutoTagSearchOutcome {
        AutoTagSearchOutcome(candidates: [candidate], warningMessage: nil)
    }

    func resolve(_ candidate: AutoTagCandidate, for request: AutoTagSearchRequest) async throws -> AutoTagProposal {
        AutoTagProposal(
            candidate: candidate, values: AutoTagValues(),
            artwork: AutoTagArtwork(
                data: M4ATestFixture.secondPNG,
                sourceURL: URL(string: "https://coverartarchive.org/release/f4cf6b7b-5d14-4f30-8a83-50a70591198f/front-1200")!
            )
        )
    }
}

// Generated structural fixtures contain two independent media chunks. They never
// read user media, and are sufficient for a metadata-only writer without a decoder.
private struct M4ATestFixture {
    let folder: URL
    let file: URL
    let original: Data
    let audio: [Data]
    let wideOffsets: Bool

    init(
        movieFirst: Bool = true,
        wideOffsets: Bool = false,
        codec: String = "mp4a",
        handler: String = "soun",
        selfContained: Bool = true,
        metadata: Data? = nil
    ) throws {
        self.wideOffsets = wideOffsets
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tagger-M4A-" + UUID().uuidString)
        file = folder.appendingPathComponent("01 - Portishead - Roads.m4a")
        let audioChunks = [Data((0..<200).map(UInt8.init)), Data(repeating: 0xAB, count: 143)]
        audio = audioChunks
        let ftyp = Self.box("ftyp", Data("M4A ".utf8) + Self.word(0) + Data("M4A isommp42".utf8))
        let media = audioChunks.map { Self.box("mdat", $0) }.reduce(Data(), +)

        func movie(offsets: [Int]) -> Data {
            let sampleHeader = Data(repeating: 0, count: 6) + Self.half(1)
                + Data(repeating: 0, count: 8) + Self.half(2) + Self.half(16)
                + Self.word(0) + Self.word(44_100 << 16)
            let sample = Self.box(codec, sampleHeader)
            let stsd = Self.box("stsd", Self.word(0) + Self.word(1) + sample)
            let positions = offsets.map { Self.word($0, width: wideOffsets ? 8 : 4) }.reduce(Data(), +)
            let stco = Self.box(wideOffsets ? "co64" : "stco", Self.word(0) + Self.word(offsets.count) + positions)
            let stts = Self.box("stts", Self.word(0) + Self.word(1) + Self.word(2) + Self.word(1_024))
            let stsc = Self.box("stsc", Self.word(0) + Self.word(1) + Self.word(1) + Self.word(1) + Self.word(1))
            let stsz = Self.box("stsz", Self.word(0) + Self.word(0) + Self.word(audioChunks.count)
                                + audioChunks.map { Self.word($0.count) }.reduce(Data(), +))
            let stbl = Self.box("stbl", stsd + stts + stsc + stsz + stco)
            let url = Self.box("url ", Self.word(selfContained ? 1 : 0)
                               + (selfContained ? Data() : Data("file:///other.m4a\0".utf8)))
            let dref = Self.box("dref", Self.word(0) + Self.word(1) + url)
            let dinf = Self.box("dinf", dref)
            let minf = Self.box("minf", Self.box("smhd", Data(repeating: 0, count: 8)) + dinf + stbl)
            let hdlr = Self.box("hdlr", Data(repeating: 0, count: 8)
                                + Data(handler.utf8) + Data(repeating: 0, count: 12) + Data([0]))
            let mdhd = Self.box("mdhd", Data(repeating: 0, count: 12)
                                + Self.word(44_100) + Self.word(2_048) + Self.word(0))
            let mdia = Self.box("mdia", mdhd + hdlr + minf)
            let trak = Self.box("trak", mdia)
            let userData: Data
            if let metadata {
                let metaHandler = Self.box("hdlr", Data(repeating: 0, count: 8)
                                          + Data("mdir".utf8) + Data("appl".utf8)
                                          + Data(repeating: 0, count: 8) + Data([0]))
                userData = Self.box("udta", Self.box("meta", Self.word(0) + metaHandler
                                       + Self.box("ilst", metadata)) + Self.unknownUserData)
            } else {
                userData = Data()
            }
            return Self.box("moov", trak + userData)
        }

        let placeholder = movie(offsets: [0, 0])
        let start = ftyp.count + Self.unrelatedBox.count + (movieFirst ? placeholder.count : 0)
        let moov = movie(offsets: [start + 8, start + 8 + audio[0].count + 8])
        original = ftyp + Self.unrelatedBox + (movieFirst ? moov + media : media + moov)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try original.write(to: file)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    static let originalDraft = ID3TagDraft(
        title: "Original Title", artist: "Original Artist", album: "Original Album",
        albumArtist: "Original Album Artist", trackNumber: "3", discNumber: "1", year: "2020",
        genre: "Electronic", composer: "A Composer", comment: "A comment",
        lyrics: "First line\nSecond line", artworkData: tinyPNG
    )

    static var taggedItems: Data {
        let fields = [
            ("©nam", originalDraft.title), ("©ART", originalDraft.artist),
            ("©alb", originalDraft.album), ("aART", originalDraft.albumArtist),
            ("©day", "2020-03-04T12:13:14Z"), ("©gen", originalDraft.genre),
            ("©wrt", originalDraft.composer), ("©cmt", originalDraft.comment),
            ("©lyr", originalDraft.lyrics),
        ]
        return fields.map { item($0.0, value: Data($0.1.utf8), type: 1) }.reduce(Data(), +)
            + item("trkn", value: half(0) + half(3) + half(12) + half(0))
            + item("disk", value: half(0) + half(1) + half(3))
            + item("covr", value: tinyPNG, type: 14) + unknownItem
    }

    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
    static let secondPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    )!
    static let unrelatedBox = box("free", Data("Unrelated container bytes".utf8))
    static let unknownUserData = box("uuid", Data((0..<32).map(UInt8.init)))
    static let unknownItem = box("----",
        box("mean", word(0) + Data("org.example.tagger-test".utf8))
        + box("name", word(0) + Data("Private application metadata".utf8))
        + box("data", word(1) + word(0) + Data("Preserve exactly".utf8))
    )

    static func item(_ name: String, value: Data, type: Int = 0) -> Data {
        box(name, box("data", word(type) + word(0) + value))
    }

    static func box(_ name: String, _ payload: Data) -> Data {
        word(payload.count + 8) + name.data(using: .isoLatin1)! + payload
    }

    static func half(_ value: Int) -> Data { word(value, width: 2) }

    static func word(_ value: Int, width: Int = 4) -> Data {
        Data((0..<width).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    static func integer(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
}

// A deliberately small independent reader checks on-disk box bytes and absolute
// offsets instead of relying on the implementation under test to verify itself.
private struct M4ATestAtom {
    let type: String
    let start: Int
    let raw: Data
    let payload: Data

    static func parse(_ bytes: Data) throws -> [Self] {
        var offset = 0
        var result: [Self] = []
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let size = M4ATestFixture.integer(bytes[offset..<(offset + 4)])
            guard size >= 8, size <= bytes.count - offset else { throw CocoaError(.fileReadCorruptFile) }
            let type = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .isoLatin1)!
            result.append(Self(type: type, start: offset,
                               raw: Data(bytes[offset..<(offset + size)]),
                               payload: Data(bytes[(offset + 8)..<(offset + size)])))
            offset += size
        }
        return result
    }

    static func find(_ path: [String], in bytes: Data) throws -> Self? {
        guard let key = path.first,
              let atom = try parse(bytes).first(where: { $0.type == key }) else { return nil }
        guard path.count > 1 else { return atom }
        let children = key == "meta" ? Data(atom.payload.dropFirst(4)) : atom.payload
        return try find(Array(path.dropFirst()), in: children)
    }
}
