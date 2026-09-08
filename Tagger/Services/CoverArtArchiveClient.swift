import AudioMarker
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol CoverArtFetching: Sendable {
    func frontCover(forReleaseID releaseID: String) async throws -> AutoTagArtwork?
}

enum CoverArtArchiveError: LocalizedError, Equatable, Sendable {
    case invalidReleaseID
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case unsupportedImage
    case invalidImage
    case imageDimensionsTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidReleaseID:
            "The selected release has an invalid Cover Art Archive identifier."
        case .invalidResponse:
            "Cover Art Archive returned an invalid response."
        case .httpStatus(let status):
            "Cover Art Archive returned HTTP \(status). Try again later."
        case .responseTooLarge:
            "The cover image exceeds the 8 MB download limit."
        case .unsupportedImage:
            "The cover image is not a supported JPEG or PNG."
        case .invalidImage:
            "The cover image could not be decoded."
        case .imageDimensionsTooLarge:
            "The cover image has dimensions that are too large to process safely."
        }
    }
}

actor CoverArtArchiveClient: CoverArtFetching {
    static let maximumDimension = 4_096
    static let maximumPixelCount = 8_000_000

    private let httpClient: any HTTPDataLoading
    private let userAgent: String

    init(
        httpClient: any HTTPDataLoading = URLSessionHTTPClient(),
        userAgent: String = "Tagger/0.1.0 (https://github.com/clt/Tagger)"
    ) {
        self.httpClient = httpClient
        self.userAgent = userAgent
    }

    func frontCover(forReleaseID releaseID: String) async throws -> AutoTagArtwork? {
        try Task.checkCancellation()
        guard let identifier = UUID(uuidString: releaseID) else {
            throw CoverArtArchiveError.invalidReleaseID
        }

        for size in [1_200, 500] {
            let url = URL(string: "https://coverartarchive.org/release/\(identifier.uuidString.lowercased())/front-\(size)")!
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("image/jpeg, image/png", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let response: HTTPResponse
            do {
                response = try await httpClient.data(for: request)
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error as? MusicBrainzError == .responseTooLarge {
                    throw CoverArtArchiveError.responseTooLarge
                }
                if error as? MusicBrainzError == .invalidResponse {
                    throw CoverArtArchiveError.invalidResponse
                }
                throw error
            }

            if response.statusCode == 404 { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw CoverArtArchiveError.httpStatus(response.statusCode)
            }
            guard response.data.count <= HTTPResponse.maximumDataSize else {
                throw CoverArtArchiveError.responseTooLarge
            }
            try validateImage(response.data)
            try Task.checkCancellation()
            return AutoTagArtwork(data: response.data, sourceURL: url)
        }
        return nil
    }

    private func validateImage(_ data: Data) throws {
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
        guard width <= Self.maximumDimension, height <= Self.maximumDimension,
              width * height <= Self.maximumPixelCount else {
            throw CoverArtArchiveError.imageDimensionsTooLarge
        }
        // Force pixel decoding now, after the dimensions have bounded its memory use.
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
    }
}
