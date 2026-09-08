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

enum AutoTagArtworkSource: Equatable, Sendable {
    case coverArtArchive
    case appleCatalog

    var displayName: String {
        switch self {
        case .coverArtArchive: "Cover Art Archive"
        case .appleCatalog: "Apple Music"
        }
    }
}

struct AutoTagArtwork: Identifiable, Equatable, Sendable {
    let data: Data
    let sourceURL: URL
    var provider: AutoTagArtworkSource = .coverArtArchive
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var title: String? = nil
    var subtitle: String? = nil
    var isOriginal = false

    var id: String { sourceURL.absoluteString }
}

struct AutoTagProposal: Equatable, Sendable {
    let candidate: AutoTagCandidate
    let values: AutoTagValues
    var artwork: AutoTagArtwork? = nil
    var artworkMessage: String? = nil
    var artworkAlternatives: [AutoTagArtwork] = []
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
    var proposal: AutoTagProposal
    var selectedFields: Set<AutoTagField>
    var isArtworkSelected: Bool
    var selectedArtworkID: String?

    init(proposal: AutoTagProposal, currentDraft: ID3TagDraft) {
        self.proposal = proposal
        selectedFields = Set(
            Self.rows(for: proposal, comparedTo: currentDraft)
                .filter { $0.currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.field)
        )
        isArtworkSelected = currentDraft.artworkData == nil && proposal.artwork != nil
        selectedArtworkID = proposal.artwork?.id
    }

    var availableArtwork: [AutoTagArtwork] {
        var identifiers: Set<String> = []
        return ((proposal.artwork.map { [$0] } ?? []) + proposal.artworkAlternatives)
            .filter { identifiers.insert($0.id).inserted }
    }

    var selectedArtwork: AutoTagArtwork? {
        availableArtwork.first { $0.id == selectedArtworkID }
    }

    func rows(comparedTo currentDraft: ID3TagDraft) -> [AutoTagReviewRow] {
        Self.rows(for: proposal, comparedTo: currentDraft)
    }

    func hasArtworkChange(comparedTo currentDraft: ID3TagDraft) -> Bool {
        guard let artwork = selectedArtwork else { return false }
        return artwork.data != currentDraft.artworkData
    }

    func applying(to currentDraft: ID3TagDraft) -> ID3TagDraft {
        var updated = currentDraft
        for field in selectedFields {
            guard let suggestion = proposal.values[field]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !suggestion.isEmpty else { continue }
            field.set(suggestion, in: &updated)
        }
        if isArtworkSelected, let artwork = selectedArtwork {
            updated.artworkData = artwork.data
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
