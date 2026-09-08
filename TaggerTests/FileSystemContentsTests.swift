import Foundation
import XCTest
@testable import Tagger

final class FileSystemContentsTests: XCTestCase {
    func testMixedAudioFormatsUseLocalizedFilenameOrderAfterFolders() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["Album 10", "Album 2"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        for name in ["10 Last.m4a", "03 Middle.MP3", "02 First.M4A", "04 Next.mp3"] {
            try Data([0x01, 0x02, 0x03]).write(to: folder.appendingPathComponent(name))
        }

        let entries = try await FileSystemService().contents(of: folder)

        XCTAssertEqual(entries.map(\.name), [
            "Album 2", "Album 10", "02 First.M4A", "03 Middle.MP3", "04 Next.mp3", "10 Last.m4a",
        ])
        XCTAssertEqual(entries.map(\.kind), [.folder, .folder, .m4a, .mp3, .mp3, .m4a])
        XCTAssertEqual(entries.map(\.isAudioFile), [false, false, true, true, true, true])
        XCTAssertEqual(entries.compactMap(\.fileSize), [3, 3, 3, 3])
    }

    func testBrowsingExcludesHiddenFilesPackagesSymlinksAndOtherFormats() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let visibleFolder = folder.appendingPathComponent("Album", isDirectory: true)
        for url in [visibleFolder, folder.appendingPathComponent(".Hidden Folder") ] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for name in ["Song.m4a", ".Hidden.m4a", ".Hidden.mp3", "Cover.jpg", "Video.mp4", "Notes.txt"] {
            try Data([0x01]).write(to: folder.appendingPathComponent(name))
        }
        let packageContents = folder.appendingPathComponent("Hidden.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: packageContents, withIntermediateDirectories: true)
        try Data([0x02]).write(to: packageContents.appendingPathComponent("Inside.m4a"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Alias.m4a"),
            withDestinationURL: folder.appendingPathComponent("Song.m4a")
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Alias Folder"),
            withDestinationURL: visibleFolder
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Missing.m4a"),
            withDestinationURL: folder.appendingPathComponent("No Such File.m4a")
        )

        let service = FileSystemService()
        let entries = try await service.contents(of: folder)
        let childFolders = try await service.childFolders(of: folder)

        XCTAssertEqual(entries.map(\.name), ["Album", "Song.m4a"])
        XCTAssertEqual(childFolders.map(\.name), ["Album"])
        XCTAssertEqual(childFolders.map(\.url), [visibleFolder.standardizedFileURL])
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tagger-Contents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
