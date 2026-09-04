import Foundation

struct FilenameTagInference: Sendable {
    func candidate(for request: AutoTagSearchRequest) -> AutoTagCandidate? {
        let values = values(for: request.fileURL)
        let hasChange = AutoTagField.allCases.contains { field in
            guard let suggestion = values[field] else { return false }
            return field.value(in: request.currentDraft) != suggestion
        }
        guard hasChange else { return nil }

        let displayTitle = values.title ?? request.fileURL.deletingPathExtension().lastPathComponent
        let displayArtist = values.artist ?? "Inferred from the selected file name"
        return AutoTagCandidate(
            id: "filename:\(request.fileURL.lastPathComponent.lowercased())",
            source: .filename,
            title: displayTitle,
            subtitle: displayArtist,
            matchScore: nil,
            reference: .filename,
            preview: values
        )
    }

    func searchSeed(for request: AutoTagSearchRequest) -> MusicBrainzSearchSeed? {
        let inferred = values(for: request.fileURL)
        guard let title = nonEmpty(request.currentDraft.title) ?? inferred.title else {
            return nil
        }

        return MusicBrainzSearchSeed(
            title: title,
            artist: nonEmpty(request.currentDraft.artist) ?? inferred.artist,
            album: nonEmpty(request.currentDraft.album)
        )
    }

    func values(for url: URL) -> AutoTagValues {
        let rawStem = url.deletingPathExtension().lastPathComponent
        var stem = normalize(rawStem.replacingOccurrences(of: "_", with: " "))
        var trackNumber: String?
        var discNumber: String?

        if let prefix = parseTrackPrefix(stem) {
            stem = prefix.remainder
            trackNumber = prefix.trackNumber
            discNumber = prefix.discNumber
        }

        let pieces = stem.components(separatedBy: " - ")
        let artist: String?
        let title: String?
        if pieces.count == 2,
           let first = nonEmpty(pieces[0]),
           let second = nonEmpty(pieces[1]) {
            artist = first
            title = second
        } else {
            artist = nil
            title = nonEmpty(stem)
        }

        return AutoTagValues(
            title: title,
            artist: artist,
            album: nil,
            albumArtist: nil,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: nil
        )
    }

    private func parseTrackPrefix(
        _ value: String
    ) -> (discNumber: String?, trackNumber: String, remainder: String)? {
        let pattern = #"^\s*(?:(\d{1,2})-)?(\d{1,3})\s*[-.]\s+(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let trackRange = Range(match.range(at: 2), in: value),
              let remainderRange = Range(match.range(at: 3), in: value),
              let track = Int(value[trackRange]),
              track > 0 else { return nil }

        let disc: String?
        if match.range(at: 1).location != NSNotFound,
           let discRange = Range(match.range(at: 1), in: value),
           let parsedDisc = Int(value[discRange]),
           parsedDisc > 0 {
            disc = String(parsedDisc)
        } else {
            disc = nil
        }

        return (
            discNumber: disc,
            trackNumber: String(track),
            remainder: normalize(String(value[remainderRange]))
        )
    }

    private func nonEmpty(_ value: String) -> String? {
        let normalized = normalize(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalize(_ value: String) -> String {
        value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
