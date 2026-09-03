import Foundation
import XCTest
@testable import Tagger

final class ID3MetadataServiceTests: XCTestCase {
    func testCreatesTagAndPreservesAudioBytes() async throws {
        let fixture = try makeFixture(named: "untagged.mp3")
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let service = ID3MetadataService()
        let loaded = try await service.load(from: fixture.file)
        XCTAssertFalse(loaded.hadID3v2Tag)
        XCTAssertEqual(loaded.draft, ID3TagDraft())

        var draft = loaded.draft
        draft.title = "A Test Song"
        draft.artist = "A Test Artist"
        draft.album = "A Test Album"
        draft.albumArtist = "Various Artists"
        draft.trackNumber = "3"
        draft.discNumber = "1"
        draft.year = "2026"
        draft.genre = "Electronic"
        draft.composer = "Test Composer"
        draft.comment = "Written by Tagger tests"
        draft.lyrics = "One line\nTwo lines"
        draft.artworkData = tinyPNG

        let saved = try await service.save(loaded, draft: draft, to: fixture.file)

        XCTAssertTrue(saved.hadID3v2Tag)
        XCTAssertEqual(saved.draft, draft)

        let writtenData = try Data(contentsOf: fixture.file)
        XCTAssertTrue(writtenData.suffix(fixture.audio.count).elementsEqual(fixture.audio))
    }

    func testRejectsID3v22WithoutWriting() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("legacy.mp3")
        let original = Data([0x49, 0x44, 0x33, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            + Data([0xFF, 0xFB, 0x90, 0x64])
        try original.write(to: file)

        let service = ID3MetadataService()

        do {
            _ = try await service.load(from: file)
            XCTFail("Expected ID3v2.2 to be rejected")
        } catch let error as ID3TagServiceError {
            XCTAssertEqual(error, .unsupportedVersion("ID3v2.2"))
        }

        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRefusesToOverwriteAFileChangedAfterLoading() async throws {
        let fixture = try makeFixture(named: "changed.mp3")
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let service = ID3MetadataService()
        let loaded = try await service.load(from: fixture.file)
        var changedData = fixture.audio
        changedData.append(0x00)
        try changedData.write(to: fixture.file)

        var draft = loaded.draft
        draft.title = "Should Not Be Written"

        do {
            _ = try await service.save(loaded, draft: draft, to: fixture.file)
            XCTFail("Expected an externally changed file to be rejected")
        } catch let error as ID3TagServiceError {
            XCTAssertEqual(error, .fileChangedExternally)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.file), changedData)
    }

    func testModifiesExistingID3v23AndPreservesUnknownFrameAndAudio() async throws {
        try await assertExistingTagRoundTrip(
            version: .v2_3,
            updatedTitle: "Modified Title"
        )
    }

    func testModifiesExistingID3v24AndPreservesUnknownFrameAndAudio() async throws {
        try await assertExistingTagRoundTrip(
            version: .v2_4,
            updatedTitle: "A Much Longer Modified Title"
        )
    }

    private func assertExistingTagRoundTrip(
        version: FixtureID3Version,
        updatedTitle: String
    ) async throws {
        let fixture = try makeTaggedFixture(
            named: "existing-v2-\(version.rawValue).mp3",
            version: version
        )
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let service = ID3MetadataService()
        let loaded = try await service.load(from: fixture.file)
        XCTAssertTrue(loaded.hadID3v2Tag)
        XCTAssertEqual(loaded.draft.title, "Original Title")

        var draft = loaded.draft
        draft.title = updatedTitle

        let saved = try await service.save(loaded, draft: draft, to: fixture.file)
        XCTAssertEqual(saved.draft.title, updatedTitle)

        let parsed = try parseTaggedFile(try Data(contentsOf: fixture.file))
        XCTAssertEqual(parsed.version, version)
        XCTAssertEqual(parsed.frames[unknownFrameID], fixture.unknownFramePayload)
        XCTAssertEqual(parsed.audio, fixture.audio)
    }

    private func makeFixture(named name: String) throws -> (folder: URL, file: URL, audio: Data) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let file = folder.appendingPathComponent(name)
        let audio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 2_048)
        try audio.write(to: file)
        return (folder, file, audio)
    }

    private func makeTaggedFixture(
        named name: String,
        version: FixtureID3Version
    ) throws -> (
        folder: URL,
        file: URL,
        audio: Data,
        unknownFramePayload: Data
    ) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let titlePayload = Data([0x00]) + Data("Original Title".utf8)
        let unknownFramePayload = Data((0..<130).map(UInt8.init))
        let frames = makeFrame(id: "TIT2", payload: titlePayload, version: version)
            + makeFrame(id: unknownFrameID, payload: unknownFramePayload, version: version)

        var tag = Data([0x49, 0x44, 0x33, version.rawValue, 0x00, 0x00])
        tag.append(contentsOf: syncsafeBytes(frames.count))
        tag.append(frames)

        let file = folder.appendingPathComponent(name)
        let audio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 2_048)
        try (tag + audio).write(to: file)

        return (folder, file, audio, unknownFramePayload)
    }

    private func makeFrame(
        id: String,
        payload: Data,
        version: FixtureID3Version
    ) -> Data {
        precondition(id.utf8.count == 4)

        var frame = Data(id.utf8)
        switch version {
        case .v2_3:
            frame.append(contentsOf: bigEndianBytes(payload.count))
        case .v2_4:
            frame.append(contentsOf: syncsafeBytes(payload.count))
        }
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(payload)
        return frame
    }

    private func parseTaggedFile(_ data: Data) throws -> (
        version: FixtureID3Version,
        frames: [String: Data],
        audio: Data
    ) {
        let bytes = [UInt8](data)
        guard bytes.count >= 10,
              Array(bytes[0..<3]) == [0x49, 0x44, 0x33],
              let version = FixtureID3Version(rawValue: bytes[3]) else {
            throw FixtureError.malformedTag
        }

        let tagSize = decodeSyncsafe(Array(bytes[6..<10]))
        let tagEnd = 10 + tagSize
        guard tagEnd <= bytes.count else {
            throw FixtureError.malformedTag
        }

        var frames: [String: Data] = [:]
        var offset = 10

        while offset + 10 <= tagEnd, bytes[offset] != 0x00 {
            guard let id = String(bytes: bytes[offset..<(offset + 4)], encoding: .isoLatin1) else {
                throw FixtureError.malformedTag
            }

            let encodedSize = Array(bytes[(offset + 4)..<(offset + 8)])
            let frameSize: Int
            switch version {
            case .v2_3:
                frameSize = decodeBigEndian(encodedSize)
            case .v2_4:
                frameSize = decodeSyncsafe(encodedSize)
            }

            let payloadStart = offset + 10
            let payloadEnd = payloadStart + frameSize
            guard payloadEnd <= tagEnd else {
                throw FixtureError.malformedTag
            }

            frames[id] = Data(bytes[payloadStart..<payloadEnd])
            offset = payloadEnd
        }

        return (version, frames, Data(bytes[tagEnd...]))
    }

    private func syncsafeBytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ]
    }

    private func bigEndianBytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func decodeSyncsafe(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    private func decodeBigEndian(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    // Valid 1×1 transparent PNG.
    private var tinyPNG: Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }

    private var unknownFrameID: String { "XZZZ" }

    private enum FixtureID3Version: UInt8 {
        case v2_3 = 3
        case v2_4 = 4
    }

    private enum FixtureError: Error {
        case malformedTag
    }
}
