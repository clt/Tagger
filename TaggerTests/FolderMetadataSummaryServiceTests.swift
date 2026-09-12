import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tagger

final class FolderMetadataSummaryServiceTests: XCTestCase {
    func testPrefersTrimmedAlbumArtistAndFallsBackToTrackArtist() async {
        let service = FolderMetadataSummaryService()
        let preferred = await service.item(from: ID3TagDraft(artist: "Track Artist", album: " Album\n", albumArtist: " Album Artist "))
        XCTAssertEqual(preferred.artist, "Album Artist")
        XCTAssertEqual(preferred.album, "Album")

        let fallback = await service.item(from: ID3TagDraft(artist: " Track Artist\n", albumArtist: " \n"))
        XCTAssertEqual(fallback.artist, "Track Artist")
        XCTAssertNil(fallback.artwork)
    }

    func testMalformedArtworkBecomesMissingCoverWithoutLosingMetadata() async {
        let service = FolderMetadataSummaryService()
        for data in [Data(), Data([0, 1, 2, 3]), Data([0x89, 0x50, 0x4E, 0x47])] {
            let item = await service.item(from: ID3TagDraft(artist: "Artist", album: "Album", artworkData: data))
            XCTAssertEqual(item.artist, "Artist")
            XCTAssertEqual(item.album, "Album")
            XCTAssertNil(item.artwork)
        }
    }

    func testArtworkIsDownsampledAndBoundedWhileHashUsesOriginalBytes() async throws {
        let original = try makeImage(width: 2_400, height: 1_200)
        let service = FolderMetadataSummaryService()
        let item = await service.item(from: ID3TagDraft(artworkData: original))
        let artwork = try XCTUnwrap(item.artwork)
        let thumbnail = try XCTUnwrap(artwork.thumbnailData)
        XCTAssertEqual(artwork.digest, Data(SHA256.hash(data: original)))
        XCTAssertNotEqual(thumbnail, original)
        XCTAssertLessThanOrEqual(thumbnail.count, FolderMetadataSummaryService.maximumThumbnailBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 200)
    }

    func testUnrelatedDraftFieldsDoNotChangeCompactItem() async {
        let service = FolderMetadataSummaryService()
        let first = await service.item(from: ID3TagDraft(artist: "Artist", album: "Album"))
        let second = await service.item(from: ID3TagDraft(
            title: "Different", artist: "Artist", album: "Album", comment: String(repeating: "Comment", count: 1_000),
            lyrics: String(repeating: "Lyrics", count: 1_000)
        ))
        XCTAssertEqual(first, second)
    }

    private func makeImage(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
