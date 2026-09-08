import Foundation

/// Routes the shared editor draft to the file's native metadata format.
/// The existing protocol and draft names are retained for MP3 compatibility.
actor AudioMetadataService: ID3MetadataServicing {
    private let mp3 = ID3MetadataService()
    private let m4a = M4AMetadataService()

    func load(from url: URL) async throws -> LoadedID3Tag {
        try await service(for: url).load(from: url)
    }

    func validateUnchanged(_ loaded: LoadedID3Tag) async throws {
        try await service(for: loaded.url).validateUnchanged(loaded)
    }

    func save(_ loaded: LoadedID3Tag, draft: ID3TagDraft) async throws -> LoadedID3Tag {
        try await service(for: loaded.url).save(loaded, draft: draft)
    }

    private func service(for url: URL) throws -> any ID3MetadataServicing {
        switch url.pathExtension.lowercased() {
        case "mp3": mp3
        case "m4a": m4a
        default: throw AudioMetadataServiceError.unsupportedFormat
        }
    }
}

enum AudioMetadataServiceError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "Choose an MP3 or M4A audio file."
    }
}
