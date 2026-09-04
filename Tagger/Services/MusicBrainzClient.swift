import Foundation

struct MusicBrainzSearchSeed: Equatable, Sendable {
    let title: String
    let artist: String?
    let album: String?
}

protocol MusicBrainzSearching: Sendable {
    func search(seed: MusicBrainzSearchSeed) async throws -> [AutoTagCandidate]
    func resolve(
        candidate: AutoTagCandidate,
        request: AutoTagSearchRequest
    ) async throws -> AutoTagProposal
}

enum MusicBrainzError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case malformedResponse
    case recordingMissingFromRelease
    case ambiguousRelease

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Tagger couldn’t create a valid MusicBrainz request."
        case .invalidResponse:
            "MusicBrainz returned an invalid response."
        case .responseTooLarge:
            "MusicBrainz returned more data than Tagger can safely process."
        case .httpStatus(let status):
            if status == 503 || status == 429 {
                "MusicBrainz is temporarily busy. Try again in a moment."
            } else {
                "MusicBrainz returned HTTP \(status)."
            }
        case .malformedResponse:
            "Tagger couldn’t understand the MusicBrainz response."
        case .recordingMissingFromRelease:
            "The selected release no longer contains this recording. Choose another result."
        case .ambiguousRelease:
            "This recording appears more than once on the selected release. Add a track or disc number and try again."
        }
    }
}

actor MusicBrainzClient: MusicBrainzSearching {
    private let httpClient: any HTTPDataLoading
    private let userAgent: String
    private let minimumInterval: Duration
    private let maximumCacheEntries: Int
    private let maximumCacheBytes: Int
    private let cacheLifetime: Duration
    private let clock = ContinuousClock()
    private var responseCache: [URL: CachedResponse] = [:]
    private var cacheAccessOrder: [URL] = []
    private var cachedByteCount = 0

    private struct CachedResponse {
        let data: Data
        let expiresAt: ContinuousClock.Instant
    }

    init(
        httpClient: any HTTPDataLoading = URLSessionHTTPClient(),
        userAgent: String = "Tagger/0.1.0 (https://github.com/clt/Tagger)",
        minimumInterval: Duration = .seconds(1),
        maximumCacheEntries: Int = 64,
        maximumCacheBytes: Int = 16 * 1_024 * 1_024,
        cacheLifetime: Duration = .seconds(900)
    ) {
        self.httpClient = httpClient
        self.userAgent = userAgent
        self.minimumInterval = minimumInterval
        self.maximumCacheEntries = maximumCacheEntries
        self.maximumCacheBytes = maximumCacheBytes
        self.cacheLifetime = cacheLifetime
    }

    func search(seed: MusicBrainzSearchSeed) async throws -> [AutoTagCandidate] {
        let url = try searchURL(for: seed)
        let response: MBRecordingSearchResponse = try await fetch(MBRecordingSearchResponse.self, from: url)
        var ranked: [(candidate: AutoTagCandidate, rank: Int)] = []

        for recording in response.recordings where recording.video != true {
            guard let recordingID = validID(recording.id),
                  let title = clean(recording.title) else { continue }

            let artist = render(recording.artistCredit)
            let releases = (recording.releases ?? [])
                .filter { validID($0.id) != nil }
                .sorted { releaseRank($0, seed: seed) > releaseRank($1, seed: seed) }

            if releases.isEmpty {
                let preview = AutoTagValues(
                    title: title,
                    artist: artist,
                    album: nil,
                    albumArtist: nil,
                    trackNumber: nil,
                    discNumber: nil,
                    year: year(from: recording.firstReleaseDate)
                )
                let candidate = AutoTagCandidate(
                    id: "musicbrainz:\(recordingID):recording",
                    source: .musicBrainz,
                    title: title,
                    subtitle: subtitle(artist: artist, album: nil, date: recording.firstReleaseDate, country: nil),
                    matchScore: score(for: recording),
                    reference: .musicBrainz(recordingID: recordingID, releaseID: nil),
                    preview: preview
                )
                ranked.append((candidate, candidateRank(recording: recording, release: nil, seed: seed)))
                continue
            }

            for release in releases.prefix(4) {
                guard let releaseID = validID(release.id) else { continue }
                let album = clean(release.title)
                let albumArtist = render(release.artistCredit)
                let releaseDate = clean(release.date) ?? clean(recording.firstReleaseDate)
                let preview = AutoTagValues(
                    title: title,
                    artist: artist,
                    album: album,
                    albumArtist: albumArtist,
                    trackNumber: nil,
                    discNumber: nil,
                    year: year(from: releaseDate)
                )
                let candidate = AutoTagCandidate(
                    id: "musicbrainz:\(recordingID):\(releaseID)",
                    source: .musicBrainz,
                    title: title,
                    subtitle: subtitle(
                        artist: artist,
                        album: album,
                        date: releaseDate,
                        country: clean(release.country)
                    ),
                    matchScore: score(for: recording),
                    reference: .musicBrainz(recordingID: recordingID, releaseID: releaseID),
                    preview: preview
                )
                ranked.append((candidate, candidateRank(recording: recording, release: release, seed: seed)))
            }
        }

        var seen: Set<String> = []
        return ranked
            .sorted {
                if $0.rank != $1.rank { return $0.rank > $1.rank }
                return $0.candidate.id < $1.candidate.id
            }
            .compactMap { item in
                guard seen.insert(item.candidate.id).inserted else { return nil }
                return item.candidate
            }
            .prefix(20)
            .map { $0 }
    }

    func resolve(
        candidate: AutoTagCandidate,
        request: AutoTagSearchRequest
    ) async throws -> AutoTagProposal {
        guard case .musicBrainz(let recordingID, let releaseID) = candidate.reference else {
            throw MusicBrainzError.invalidRequest
        }
        guard let recordingID = validID(recordingID) else {
            throw MusicBrainzError.invalidRequest
        }
        guard let releaseID else {
            return AutoTagProposal(candidate: candidate, values: candidate.preview)
        }
        guard let releaseID = validID(releaseID) else {
            throw MusicBrainzError.invalidRequest
        }

        let url = try releaseURL(for: releaseID)
        let release: MBReleaseDetail = try await fetch(MBReleaseDetail.self, from: url)
        var matches: [(medium: MBMedium, track: MBTrack)] = []
        for medium in release.media ?? [] {
            for track in medium.tracks ?? [] where validID(track.recording?.id) == recordingID {
                matches.append((medium, track))
            }
        }

        guard !matches.isEmpty else {
            throw MusicBrainzError.recordingMissingFromRelease
        }

        let inferred = FilenameTagInference().values(for: request.fileURL)
        let preferredDisc = Int(request.currentDraft.discNumber) ?? inferred.discNumber.flatMap(Int.init)
        let preferredTrack = Int(request.currentDraft.trackNumber) ?? inferred.trackNumber.flatMap(Int.init)

        if let preferredDisc {
            let filtered = matches.filter { $0.medium.position == preferredDisc }
            if !filtered.isEmpty { matches = filtered }
        }
        if let preferredTrack {
            let filtered = matches.filter { $0.track.position == preferredTrack }
            if !filtered.isEmpty { matches = filtered }
        }

        guard matches.count == 1, let match = matches.first else {
            throw MusicBrainzError.ambiguousRelease
        }

        let trackArtist = render(match.track.artistCredit)
            ?? render(match.track.recording?.artistCredit)
            ?? candidate.preview.artist
        let title = clean(match.track.title)
            ?? clean(match.track.recording?.title)
            ?? candidate.preview.title
        let values = AutoTagValues(
            title: title,
            artist: trackArtist,
            album: clean(release.title) ?? candidate.preview.album,
            albumArtist: render(release.artistCredit) ?? candidate.preview.albumArtist,
            trackNumber: positiveNumber(match.track.position),
            discNumber: positiveNumber(match.medium.position),
            year: year(from: release.date) ?? candidate.preview.year
        )
        return AutoTagProposal(candidate: candidate, values: values)
    }

    private func searchURL(for seed: MusicBrainzSearchSeed) throws -> URL {
        guard let title = clean(seed.title) else { throw MusicBrainzError.invalidRequest }
        var clauses = ["recording:\"\(luceneEscape(title))\""]
        if let artist = clean(seed.artist) {
            clauses.append("artist:\"\(luceneEscape(artist))\"")
        }
        if let album = clean(seed.album) {
            clauses.append("release:\"\(luceneEscape(album))\"")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/recording"
        components.queryItems = [
            URLQueryItem(name: "query", value: clauses.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else { throw MusicBrainzError.invalidRequest }
        return url
    }

    private func releaseURL(for releaseID: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/release/\(releaseID)"
        components.queryItems = [
            URLQueryItem(
                name: "inc",
                value: "recordings+artist-credits+release-groups"
            ),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { throw MusicBrainzError.invalidRequest }
        return url
    }

    private func fetch<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) async throws -> Value {
        try Task.checkCancellation()
        if let cached = cachedData(for: url) {
            return try decode(type, from: cached)
        }

        try await MusicBrainzRequestLimiter.shared.waitForRequestSlot(minimumInterval: minimumInterval)
        try Task.checkCancellation()
        // Another request may have populated this entry while we waited for the limiter.
        if let cached = cachedData(for: url) {
            return try decode(type, from: cached)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let response = try await httpClient.data(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw MusicBrainzError.httpStatus(response.statusCode)
        }
        guard response.data.count <= HTTPResponse.maximumDataSize else {
            throw MusicBrainzError.responseTooLarge
        }

        let decoded = try decode(type, from: response.data)
        cache(response.data, for: url)
        return decoded
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MusicBrainzError.malformedResponse
        }
    }

    private func cachedData(for url: URL) -> Data? {
        guard let cached = responseCache[url] else { return nil }
        guard cached.expiresAt > clock.now else {
            removeCachedResponse(for: url)
            return nil
        }
        cacheAccessOrder.removeAll { $0 == url }
        cacheAccessOrder.append(url)
        return cached.data
    }

    private func cache(_ data: Data, for url: URL) {
        guard maximumCacheEntries > 0,
              maximumCacheBytes > 0,
              cacheLifetime > .zero,
              data.count <= maximumCacheBytes else { return }
        removeCachedResponse(for: url)
        let expiredURLs = responseCache.compactMap { key, value in
            value.expiresAt <= clock.now ? key : nil
        }
        for expiredURL in expiredURLs { removeCachedResponse(for: expiredURL) }
        while responseCache.count >= maximumCacheEntries
            || cachedByteCount > maximumCacheBytes - data.count {
            guard let oldestURL = cacheAccessOrder.first else { break }
            removeCachedResponse(for: oldestURL)
        }
        responseCache[url] = CachedResponse(
            data: data,
            expiresAt: clock.now.advanced(by: cacheLifetime)
        )
        cachedByteCount += data.count
        cacheAccessOrder.append(url)
    }

    private func removeCachedResponse(for url: URL) {
        if let removed = responseCache.removeValue(forKey: url) {
            cachedByteCount -= removed.data.count
        }
        cacheAccessOrder.removeAll { $0 == url }
    }

    private func luceneEscape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]", "^", "\"", "~", "*", "?", ":", "\\", "/":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private func candidateRank(
        recording: MBRecording,
        release: MBReleaseSummary?,
        seed: MusicBrainzSearchSeed
    ) -> Int {
        var rank = score(for: recording) ?? 0
        if normalized(recording.title) == normalized(seed.title) { rank += 35 }
        if let artist = seed.artist,
           normalized(render(recording.artistCredit)) == normalized(artist) {
            rank += 20
        }
        if let album = seed.album,
           normalized(release?.title) == normalized(album) {
            rank += 15
        }
        if release?.status == "Official" { rank += 2 }
        return rank
    }

    private func releaseRank(_ release: MBReleaseSummary, seed: MusicBrainzSearchSeed) -> Int {
        var rank = release.status == "Official" ? 2 : 0
        if let album = seed.album,
           normalized(release.title) == normalized(album) {
            rank += 10
        }
        if release.date != nil { rank += 1 }
        return rank
    }

    private func subtitle(
        artist: String?,
        album: String?,
        date: String?,
        country: String?
    ) -> String {
        var pieces: [String] = []
        if let artist = clean(artist) { pieces.append(artist) }
        if let album = clean(album) { pieces.append(album) }
        if let year = year(from: date) { pieces.append(year) }
        if let country = clean(country) { pieces.append(country) }
        return pieces.isEmpty ? "Recording match" : pieces.joined(separator: " • ")
    }

    private func render(_ credits: [MBArtistCredit]?) -> String? {
        guard let credits, !credits.isEmpty else { return nil }
        let rendered = credits.map { credit in
            (clean(credit.name) ?? clean(credit.artist?.name) ?? "") + (credit.joinphrase ?? "")
        }.joined()
        return clean(rendered)
    }

    private func year(from date: String?) -> String? {
        guard let date = clean(date), date.count >= 4 else { return nil }
        let prefix = String(date.prefix(4))
        guard prefix.utf8.count == 4,
              prefix.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(prefix), value > 0 else { return nil }
        return prefix
    }

    private func positiveNumber(_ value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(value)
    }

    private func validID(_ value: String?) -> String? {
        guard let value = clean(value), let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func score(for recording: MBRecording) -> Int? {
        guard let score = recording.score?.value, (0...100).contains(score) else { return nil }
        return score
    }

    private func normalized(_ value: String?) -> String {
        clean(value)?
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) ?? ""
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private actor MusicBrainzRequestLimiter {
    static let shared = MusicBrainzRequestLimiter()

    private let clock = ContinuousClock()
    private var nextRequestTime: ContinuousClock.Instant?

    func waitForRequestSlot(minimumInterval: Duration) async throws {
        guard minimumInterval > .zero else { return }
        while true {
            try Task.checkCancellation()
            let now = clock.now
            if let nextRequestTime, nextRequestTime > now {
                try await clock.sleep(until: nextRequestTime)
                // Recheck after suspension: another client may already have taken this slot.
                continue
            }
            nextRequestTime = now.advanced(by: minimumInterval)
            return
        }
    }
}

private struct MBRecordingSearchResponse: Decodable {
    let recordings: [MBRecording]
}

private struct MBRecording: Decodable {
    let id: String?
    let score: FlexibleInt?
    let title: String?
    let video: Bool?
    let artistCredit: [MBArtistCredit]?
    let firstReleaseDate: String?
    let releases: [MBReleaseSummary]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, video, releases
        case artistCredit = "artist-credit"
        case firstReleaseDate = "first-release-date"
    }
}

private struct MBReleaseSummary: Decodable {
    let id: String?
    let title: String?
    let status: String?
    let date: String?
    let country: String?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, status, date, country
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit: Decodable {
    let name: String?
    let joinphrase: String?
    let artist: MBArtist?
}

private struct MBArtist: Decodable {
    let name: String?
}

private struct MBReleaseDetail: Decodable {
    let title: String?
    let date: String?
    let artistCredit: [MBArtistCredit]?
    let media: [MBMedium]?

    enum CodingKeys: String, CodingKey {
        case title, date, media
        case artistCredit = "artist-credit"
    }
}

private struct MBMedium: Decodable {
    let position: Int?
    let tracks: [MBTrack]?
}

private struct MBTrack: Decodable {
    let position: Int?
    let title: String?
    let artistCredit: [MBArtistCredit]?
    let recording: MBTrackRecording?

    enum CodingKeys: String, CodingKey {
        case position, title, recording
        case artistCredit = "artist-credit"
    }
}

private struct MBTrackRecording: Decodable {
    let id: String?
    let title: String?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title
        case artistCredit = "artist-credit"
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            value = integer
        } else if let string = try? container.decode(String.self),
                  let integer = Int(string) {
            value = integer
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an integer or numeric string."
                )
            )
        }
    }
}
