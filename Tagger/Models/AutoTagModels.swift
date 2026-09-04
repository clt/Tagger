import Foundation

struct AutoTagSearchRequest: Equatable, Sendable {
    let fileURL: URL
    let currentDraft: ID3TagDraft
    let searchSeed: MusicBrainzSearchSeed?

    init(fileURL: URL, currentDraft: ID3TagDraft, searchSeed: MusicBrainzSearchSeed? = nil) {
        self.fileURL = fileURL
        self.currentDraft = currentDraft
        self.searchSeed = searchSeed
    }
}

struct AutoTagSearchOutcome: Equatable, Sendable {
    let candidates: [AutoTagCandidate]
    let warningMessage: String?
}

enum AutoTagSource: String, Equatable, Sendable {
    case filename
    case musicBrainz

    var displayName: String {
        switch self {
        case .filename:
            "File Name"
        case .musicBrainz:
            "MusicBrainz"
        }
    }
}

enum AutoTagReference: Equatable, Sendable {
    case filename
    case musicBrainz(recordingID: String, releaseID: String?)
}

struct AutoTagCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let source: AutoTagSource
    let title: String
    let subtitle: String
    let matchScore: Int?
    let reference: AutoTagReference
    let preview: AutoTagValues
}

struct AutoTagProposal: Equatable, Sendable {
    let candidate: AutoTagCandidate
    let values: AutoTagValues
}

struct AutoTagValues: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: String?
    var discNumber: String?
    var year: String?

    subscript(field: AutoTagField) -> String? {
        switch field {
        case .title:
            title
        case .artist:
            artist
        case .album:
            album
        case .albumArtist:
            albumArtist
        case .trackNumber:
            trackNumber
        case .discNumber:
            discNumber
        case .year:
            year
        }
    }
}

enum AutoTagField: String, CaseIterable, Hashable, Identifiable, Sendable {
    case title
    case artist
    case album
    case albumArtist
    case trackNumber
    case discNumber
    case year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title:
            "Title"
        case .artist:
            "Artist"
        case .album:
            "Album"
        case .albumArtist:
            "Album Artist"
        case .trackNumber:
            "Track Number"
        case .discNumber:
            "Disc Number"
        case .year:
            "Year"
        }
    }

    func value(in draft: ID3TagDraft) -> String {
        switch self {
        case .title:
            draft.title
        case .artist:
            draft.artist
        case .album:
            draft.album
        case .albumArtist:
            draft.albumArtist
        case .trackNumber:
            draft.trackNumber
        case .discNumber:
            draft.discNumber
        case .year:
            draft.year
        }
    }

    func set(_ value: String, in draft: inout ID3TagDraft) {
        switch self {
        case .title:
            draft.title = value
        case .artist:
            draft.artist = value
        case .album:
            draft.album = value
        case .albumArtist:
            draft.albumArtist = value
        case .trackNumber:
            draft.trackNumber = value
        case .discNumber:
            draft.discNumber = value
        case .year:
            draft.year = value
        }
    }
}

struct AutoTagReviewRow: Identifiable, Equatable, Sendable {
    let field: AutoTagField
    let currentValue: String
    let suggestedValue: String

    var id: AutoTagField { field }
}

struct AutoTagReviewDraft: Equatable, Sendable {
    let proposal: AutoTagProposal
    var selectedFields: Set<AutoTagField>

    init(proposal: AutoTagProposal, currentDraft: ID3TagDraft) {
        self.proposal = proposal
        selectedFields = Set(
            Self.rows(for: proposal, comparedTo: currentDraft)
                .filter { $0.currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.field)
        )
    }

    func rows(comparedTo currentDraft: ID3TagDraft) -> [AutoTagReviewRow] {
        Self.rows(for: proposal, comparedTo: currentDraft)
    }

    func applying(to currentDraft: ID3TagDraft) -> ID3TagDraft {
        var updated = currentDraft
        for field in selectedFields {
            guard let suggestion = proposal.values[field]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !suggestion.isEmpty else { continue }
            field.set(suggestion, in: &updated)
        }
        return updated
    }

    func hasSelectedChanges(comparedTo currentDraft: ID3TagDraft) -> Bool {
        applying(to: currentDraft) != currentDraft
    }

    private static func rows(
        for proposal: AutoTagProposal,
        comparedTo currentDraft: ID3TagDraft
    ) -> [AutoTagReviewRow] {
        AutoTagField.allCases.compactMap { field in
            guard let suggestion = proposal.values[field]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !suggestion.isEmpty else { return nil }

            let current = field.value(in: currentDraft)
            guard current != suggestion else { return nil }
            return AutoTagReviewRow(
                field: field,
                currentValue: current,
                suggestedValue: suggestion
            )
        }
    }
}

enum AutoTagPhase: Equatable, Sendable {
    case idle
    case searching
    case choosing
    case resolving
    case reviewing
    case noResults
}
