import Foundation
import XCTest
@testable import Tagger

final class FileSystemRenameTests: XCTestCase {
    func testValidateAndRenameMovesFileWithoutChangingBytes() async throws {
        let fixture = try makeFixture(files: ["Original.mp3": Data([0x01, 0x02, 0x03])])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let source = fixture.folder.appendingPathComponent("Original.mp3")
        let expectedDestination = fixture.folder.appendingPathComponent("Renamed.mp3")
        let service = FileSystemService()

        let destination = try await service.validateRename(
            from: source,
            toFileName: "Renamed.mp3"
        )
        XCTAssertEqual(destination, expectedDestination.standardizedFileURL)

        try await service.rename(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x01, 0x02, 0x03]))
    }

    func testCollisionIsRefusedWithoutOverwritingEitherFile() async throws {
        let sourceData = Data([0x01, 0x02])
        let destinationData = Data([0xA0, 0xB0, 0xC0])
        let fixture = try makeFixture(files: [
            "Original.mp3": sourceData,
            "Taken.mp3": destinationData,
        ])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let source = fixture.folder.appendingPathComponent("Original.mp3")
        let destination = fixture.folder.appendingPathComponent("Taken.mp3")
        let service = FileSystemService()

        do {
            _ = try await service.validateRename(from: source, toFileName: "Taken.mp3")
            XCTFail("Expected validation to reject an existing destination")
        } catch let error as FileRenameError {
            XCTAssertEqual(error, .destinationExists("Taken.mp3"))
        }

        do {
            try await service.rename(from: source, to: destination)
            XCTFail("Expected rename to reject an existing destination")
        } catch let error as FileRenameError {
            XCTAssertEqual(error, .destinationExists("Taken.mp3"))
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(try Data(contentsOf: destination), destinationData)
    }

    func testOverlongFilenameIsRejectedBeforeRenameAndLeavesSourceIntact() async throws {
        let sourceData = Data([0x49, 0x44, 0x33, 0x01, 0x02, 0x03])
        let fixture = try makeFixture(files: ["Original.mp3": sourceData])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let source = fixture.folder.appendingPathComponent("Original.mp3")
        let overlongFilename = String(repeating: "a", count: 1_024) + ".mp3"
        let service = FileSystemService()

        do {
            _ = try await service.validateRename(
                from: source,
                toFileName: overlongFilename
            )
            XCTFail("Expected validation to reject an overlong file name")
        } catch let error as FileRenameError {
            XCTAssertEqual(error, .fileNameTooLong)
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path),
            ["Original.mp3"]
        )
    }

    func testCaseOnlyRenamePreservesFileAndRequestedSpelling() async throws {
        let originalData = Data([0x49, 0x44, 0x33])
        let fixture = try makeFixture(files: ["Song.mp3": originalData])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let source = fixture.folder.appendingPathComponent("Song.mp3")
        let service = FileSystemService()
        let destination = try await service.validateRename(
            from: source,
            toFileName: "song.mp3"
        )

        try await service.rename(from: source, to: destination)

        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
        XCTAssertEqual(names, ["song.mp3"])
        XCTAssertEqual(try Data(contentsOf: destination), originalData)
    }

    func testSymlinkSourceIsRejectedWithoutMovingItsTarget() async throws {
        let originalData = Data([0x49, 0x44, 0x33])
        let fixture = try makeFixture(files: ["Real.mp3": originalData])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let target = fixture.folder.appendingPathComponent("Real.mp3")
        let source = fixture.folder.appendingPathComponent("Alias.mp3")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let service = FileSystemService()

        do {
            _ = try await service.validateRename(from: source, toFileName: "Renamed.mp3")
            XCTFail("Expected a symbolic-link source to be rejected")
        } catch let error as FileRenameError {
            XCTAssertEqual(error, .sourceUnavailable("Alias.mp3"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: target), originalData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.folder.appendingPathComponent("Renamed.mp3").path
            )
        )
    }

    func testDanglingSymlinkDestinationIsTreatedAsACollision() async throws {
        let sourceData = Data([0x49, 0x44, 0x33])
        let fixture = try makeFixture(files: ["Original.mp3": sourceData])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let source = fixture.folder.appendingPathComponent("Original.mp3")
        let destination = fixture.folder.appendingPathComponent("Taken.mp3")
        let missingTarget = fixture.folder.appendingPathComponent("Missing.mp3")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: missingTarget
        )
        let service = FileSystemService()

        do {
            _ = try await service.validateRename(from: source, toFileName: "Taken.mp3")
            XCTFail("Expected a dangling symbolic link to count as an existing destination")
        } catch let error as FileRenameError {
            XCTAssertEqual(error, .destinationExists("Taken.mp3"))
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            missingTarget.path
        )
    }

    private func makeFixture(files: [String: Data]) throws -> (folder: URL, files: [URL]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var urls: [URL] = []
        for (name, data) in files {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            urls.append(url)
        }
        return (folder, urls)
    }
}
