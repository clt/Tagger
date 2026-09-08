import Foundation

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

        var imageFailure: CoverArtArchiveError?
        for endpoint in ["front", "front-1200", "front-500"] {
            try Task.checkCancellation()
            let url = URL(string: "https://coverartarchive.org/release/\(identifier.uuidString.lowercased())/\(endpoint)")!
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
                    imageFailure = .responseTooLarge
                    continue
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
            if response.data.count > HTTPResponse.maximumDataSize {
                imageFailure = .responseTooLarge
                continue
            }
            let dimensions: (width: Int, height: Int)
            do {
                dimensions = try ArtworkImageValidator.dimensions(of: response.data)
            } catch let error as CoverArtArchiveError {
                try Task.checkCancellation()
                imageFailure = error
                continue
            }
            try Task.checkCancellation()
            return AutoTagArtwork(
                data: response.data, sourceURL: url,
                pixelWidth: dimensions.width, pixelHeight: dimensions.height,
                isOriginal: endpoint == "front"
            )
        }
        try Task.checkCancellation()
        if let imageFailure { throw imageFailure }
        return nil
    }
}
