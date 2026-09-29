import Foundation

/// A compact artwork identity and display image, never the original embedded cover.
struct FolderSummaryArtwork: Equatable, Sendable {
    let digest: Data
    let thumbnailData: Data?
}

/// Only the metadata needed to summarize a folder is retained for each readable file.
struct FolderMetadataItem: Equatable, Sendable {
    let artist: String
    let album: String
    let artwork: FolderSummaryArtwork?
}

struct FolderMetadataSummary: Equatable, Sendable {
    let artistText: String
    let albumText: String
    let artworkData: Data?
    let artworkPlaceholder: String
    let fileCount: Int
    let unreadableCount: Int
    let missingMetadataCount: Int
    let missingArtworkCount: Int

    init(items: [FolderMetadataItem], fileCount: Int, unreadableCount: Int = 0) {
        let artists = Set(items.map { Self.normalized($0.artist) }.filter { !$0.isEmpty })
        let albums = Set(items.map { Self.normalized($0.album) }.filter { !$0.isEmpty })
        artistText = Self.label(artists, unknown: "Unknown artist", multiple: "Multiple artists")
        albumText = Self.label(albums, unknown: "Unknown album", multiple: "Multiple albums")
        self.fileCount = fileCount
        self.unreadableCount = unreadableCount
        missingMetadataCount = items.filter {
            Self.normalized($0.artist).isEmpty || Self.normalized($0.album).isEmpty
        }.count
        missingArtworkCount = items.filter { $0.artwork == nil }.count

        let covers = items.compactMap(\.artwork)
        let coverIdentities = Set(covers.map(\.digest))
        artworkData = coverIdentities.count == 1
            ? covers.lazy.compactMap(\.thumbnailData).first
            : nil
        artworkPlaceholder = coverIdentities.count > 1 ? "Multiple covers" : "No cover"
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func label(_ values: Set<String>, unknown: String, multiple: String) -> String {
        if values.isEmpty { return unknown }
        return values.count == 1 ? values.first! : multiple
    }
}
