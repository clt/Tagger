import Foundation
import XCTest
@testable import Tagger

final class FolderMetadataSummaryTests: XCTestCase {
    func testEmptyFolderUsesPlaceholders() {
        let summary = FolderMetadataSummary(items: [], fileCount: 0)
        XCTAssertEqual(summary.albumText, "Unknown album")
        XCTAssertEqual(summary.artistText, "Unknown artist")
        XCTAssertEqual(summary.artworkPlaceholder, "No cover")
        XCTAssertNil(summary.artworkData)
        XCTAssertEqual(summary.missingMetadataCount, 0)
    }

    func testPartialMetadataKeepsKnownValuesAndCountsFilesOnce() {
        let cover = FolderSummaryArtwork(digest: Data([1]), thumbnailData: Data([2]))
        let summary = FolderMetadataSummary(items: [
            FolderMetadataItem(artist: " Artist\n", album: "Album", artwork: cover),
            FolderMetadataItem(artist: "", album: " Album ", artwork: nil),
            FolderMetadataItem(artist: "\n", album: " ", artwork: nil),
        ], fileCount: 4, unreadableCount: 1)

        XCTAssertEqual(summary.artistText, "Artist")
        XCTAssertEqual(summary.albumText, "Album")
        XCTAssertEqual(summary.missingMetadataCount, 2)
        XCTAssertEqual(summary.missingArtworkCount, 2)
        XCTAssertEqual(summary.fileCount, 4)
        XCTAssertEqual(summary.unreadableCount, 1)
        XCTAssertEqual(summary.artworkData, cover.thumbnailData)
    }

    func testDifferentMetadataAndArtworkShowMixedPlaceholders() {
        let summary = FolderMetadataSummary(items: [
            FolderMetadataItem(artist: "One", album: "First", artwork: .init(digest: Data([1]), thumbnailData: Data([3]))),
            FolderMetadataItem(artist: "Two", album: "Second", artwork: .init(digest: Data([2]), thumbnailData: Data([3]))),
        ], fileCount: 2)

        XCTAssertEqual(summary.artistText, "Multiple artists")
        XCTAssertEqual(summary.albumText, "Multiple albums")
        XCTAssertEqual(summary.artworkPlaceholder, "Multiple covers")
        XCTAssertNil(summary.artworkData)
    }

    func testSharedArtworkUsesOriginalIdentityAndAvailableThumbnail() {
        let summary = FolderMetadataSummary(items: [
            FolderMetadataItem(artist: "Beyonc\u{00E9}", album: "Album", artwork: .init(digest: Data([1]), thumbnailData: nil)),
            FolderMetadataItem(artist: "Beyonce\u{0301}", album: "Album", artwork: .init(digest: Data([1]), thumbnailData: Data([3]))),
        ], fileCount: 2)

        XCTAssertEqual(summary.artistText, "Beyonc\u{00E9}")
        XCTAssertEqual(summary.artworkData, Data([3]))
        XCTAssertEqual(summary.missingArtworkCount, 0)
    }
}
