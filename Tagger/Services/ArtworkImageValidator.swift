import AudioMarker
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArtworkImageValidator {
    static let maximumDimension = 4_096
    static let maximumPixelCount = 16_777_216

    static func dimensions(of data: Data) throws -> (width: Int, height: Int) {
        guard (try? Artwork(data: data)) != nil else {
            throw CoverArtArchiveError.unsupportedImage
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            throw CoverArtArchiveError.invalidImage
        }
        guard type == UTType.jpeg.identifier || type == UTType.png.identifier else {
            throw CoverArtArchiveError.unsupportedImage
        }
        guard CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw CoverArtArchiveError.invalidImage
        }
        guard width <= maximumDimension, height <= maximumDimension,
              width * height <= maximumPixelCount else {
            throw CoverArtArchiveError.imageDimensionsTooLarge
        }
        // Force pixel decoding only after the dimensions have bounded its memory use.
        let options = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height,
              let decodedPixels = image.dataProvider?.data,
              CFDataGetLength(decodedPixels) >= image.bytesPerRow * image.height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw CoverArtArchiveError.invalidImage
        }
        return (width, height)
    }
}
