import Foundation

protocol AppleArtworkSearching: Sendable {
    func search(artist: String, album: String) async throws -> ArtworkSearchOutcome
}

struct ArtworkSearchOutcome: Sendable {
    let artworks: [AutoTagArtwork]
    let warningMessage: String?

    init(artworks: [AutoTagArtwork], warningMessage: String? = nil) {
        self.artworks = artworks
        self.warningMessage = warningMessage
    }
}

enum AppleArtworkError: LocalizedError, Equatable, Sendable {
    case invalidSearch
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case malformedResponse
    case unsafeURL

    var errorDescription: String? {
        switch self {
        case .invalidSearch: "Enter an artist and album to search Apple Music artwork."
        case .invalidResponse: "Apple Music returned an invalid response."
        case .httpStatus(let status): "Apple Music returned HTTP \(status). Try again later."
        case .responseTooLarge: "Apple Music returned more than the 8 MB download limit."
        case .malformedResponse: "Tagger couldn’t understand the Apple Music catalog response."
        case .unsafeURL: "Apple Music returned an unsupported artwork or album URL."
        }
    }
}

actor AppleArtworkClient: AppleArtworkSearching {
    private let httpClient: any HTTPDataLoading
    private let minimumInterval: Duration
    private let userAgent: String

    init(
        httpClient: any HTTPDataLoading = URLSessionHTTPClient(),
        minimumInterval: Duration = .milliseconds(3_100),
        userAgent: String = "Tagger/0.1.0 (https://github.com/clt/Tagger)"
    ) {
        self.httpClient = httpClient
        self.minimumInterval = minimumInterval
        self.userAgent = userAgent
    }

    func search(artist: String, album: String) async throws -> ArtworkSearchOutcome {
        try Task.checkCancellation()
        guard let artist = clean(artist), let album = clean(album) else {
            throw AppleArtworkError.invalidSearch
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw AppleArtworkError.invalidSearch }
        try await AppleArtworkSearchLimiter.shared.wait(minimumInterval: minimumInterval)
        let data = try await fetch(url, accept: "application/json")
        let response: AppleAlbumSearchResponse
        do {
            response = try JSONDecoder().decode(AppleAlbumSearchResponse.self, from: data)
        } catch {
            throw AppleArtworkError.malformedResponse
        }

        var seen: Set<Int> = []
        let albums = response.results.filter {
            $0.wrapperType == "collection" && $0.collectionType == "Album"
                && normalized($0.artistName) == normalized(artist)
                && matchesAlbum($0.collectionName, requested: album)
                && ($0.collectionId ?? 0) > 0
        }.filter { seen.insert($0.collectionId!).inserted }.prefix(3)
        var artworks: [AutoTagArtwork] = []
        var failures: [String] = []
        for album in albums {
            try Task.checkCancellation()
            do {
                let artwork = try await artwork(for: album)
                try Task.checkCancellation()
                artworks.append(artwork)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                failures.append(error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        return ArtworkSearchOutcome(
            artworks: artworks,
            warningMessage: failures.first.map { "Some Apple Music artwork couldn’t be loaded. \($0)" }
        )
    }

    private func artwork(for album: AppleAlbum) async throws -> AutoTagArtwork {
        let suppliedURL = try trustedURL(album.artworkUrl100, image: true)
        let sourceURL = try trustedURL(album.collectionViewUrl, image: false)
        var components = URLComponents(url: suppliedURL, resolvingAgainstBaseURL: false)!
        let thumbnailSuffix = "/100x100bb.jpg"
        var urls = [suppliedURL]
        if components.percentEncodedPath.hasSuffix(thumbnailSuffix) {
            // Larger sizes work on Apple's CDN, but are not documented by the Search API.
            // Fall back to the supplied URL and report decoded dimensions, never "original".
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast(thumbnailSuffix.count))
                + "/3000x3000bb.jpg"
            if let largerURL = components.url { urls.insert(largerURL, at: 0) }
        }
        for (index, url) in urls.enumerated() {
            do {
                let data = try await fetch(url, accept: "image/jpeg, image/png")
                let dimensions = try ArtworkImageValidator.dimensions(of: data)
                try Task.checkCancellation()
                return AutoTagArtwork(
                    data: data, sourceURL: sourceURL, provider: .appleCatalog,
                    pixelWidth: dimensions.width, pixelHeight: dimensions.height,
                    title: clean(album.collectionName),
                    subtitle: [clean(album.artistName), clean(album.releaseDate).map { String($0.prefix(10)) }]
                        .compactMap { $0 }.joined(separator: " • "),
                    isOriginal: false
                )
            } catch {
                try Task.checkCancellation()
                if index + 1 < urls.count, canFallBack(after: error) { continue }
                throw error
            }
        }
        throw AppleArtworkError.invalidResponse
    }

    private func fetch(_ url: URL, accept: String) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do {
            response = try await httpClient.data(for: request)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if error as? MusicBrainzError == .responseTooLarge { throw AppleArtworkError.responseTooLarge }
            if error as? MusicBrainzError == .invalidResponse { throw AppleArtworkError.invalidResponse }
            throw error
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppleArtworkError.httpStatus(response.statusCode)
        }
        guard response.data.count <= HTTPResponse.maximumDataSize else {
            throw AppleArtworkError.responseTooLarge
        }
        return response.data
    }

    private func canFallBack(after error: Error) -> Bool {
        if let error = error as? AppleArtworkError {
            return error == .httpStatus(404) || error == .responseTooLarge
        }
        if let error = error as? CoverArtArchiveError {
            return error == .unsupportedImage || error == .invalidImage || error == .imageDimensionsTooLarge
        }
        return false
    }

    private func trustedURL(_ value: String?, image: Bool) throws -> URL {
        guard let value, let url = URL(string: value), let host = url.host?.lowercased(),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              image ? (host == "mzstatic.com" || host.hasSuffix(".mzstatic.com"))
                  : (host == "music.apple.com" || host == "itunes.apple.com") else {
            throw AppleArtworkError.unsafeURL
        }
        return url
    }

    private func matchesAlbum(_ value: String?, requested: String) -> Bool {
        let candidate = normalized(value)
        let requested = normalized(requested)
        return candidate == requested || [" (", " [", " - ", ": "].contains {
            candidate.hasPrefix(requested + $0)
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return cleaned.isEmpty ? nil : cleaned
    }

    private func normalized(_ value: String?) -> String {
        clean(value)?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) ?? ""
    }
}

private struct AppleAlbumSearchResponse: Decodable {
    let results: [AppleAlbum]
}

private struct AppleAlbum: Decodable {
    let wrapperType: String?
    let collectionType: String?
    let collectionId: Int?
    let artistName: String?
    let collectionName: String?
    let releaseDate: String?
    let artworkUrl100: String?
    let collectionViewUrl: String?
}

private actor AppleArtworkSearchLimiter {
    static let shared = AppleArtworkSearchLimiter()
    private let clock = ContinuousClock()
    private var nextSearch: ContinuousClock.Instant?

    func wait(minimumInterval: Duration) async throws {
        guard minimumInterval > .zero else { return }
        while true {
            try Task.checkCancellation()
            let now = clock.now
            if let nextSearch, nextSearch > now {
                try await clock.sleep(until: nextSearch)
                continue
            }
            nextSearch = now.advanced(by: minimumInterval)
            return
        }
    }
}
