import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol FolderMetadataSummarizing: Sendable {
    func item(from draft: ID3TagDraft) async -> FolderMetadataItem
}

/// Builds compact, read-only display values away from the main actor.
actor FolderMetadataSummaryService: FolderMetadataSummarizing {
    static let maximumThumbnailDimension = 400
    static let maximumThumbnailBytes = 1_048_576

    func item(from draft: ID3TagDraft) async -> FolderMetadataItem {
        let albumArtist = FolderMetadataSummary.normalized(draft.albumArtist)
        return FolderMetadataItem(
            artist: albumArtist.isEmpty ? FolderMetadataSummary.normalized(draft.artist) : albumArtist,
            album: FolderMetadataSummary.normalized(draft.album),
            artwork: draft.artworkData.flatMap(Self.compactArtwork)
        )
    }

    private static func compactArtwork(_ data: Data) -> FolderSummaryArtwork? {
        guard !Task.isCancelled, !data.isEmpty else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              image.width > 0, image.height > 0,
              image.width <= maximumThumbnailDimension, image.height <= maximumThumbnailDimension,
              let pixels = image.dataProvider?.data,
              CFDataGetLength(pixels) >= image.bytesPerRow * image.height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              !Task.isCancelled else { return nil }
        let thumbnail = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(thumbnail, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), thumbnail.length <= maximumThumbnailBytes else { return nil }
        return FolderSummaryArtwork(digest: Data(SHA256.hash(data: data)), thumbnailData: thumbnail as Data)
    }
}
