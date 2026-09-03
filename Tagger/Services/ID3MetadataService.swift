import AudioMarker
import CryptoKit
import Foundation

protocol ID3MetadataServicing: Sendable {
    func load(from url: URL) async throws -> LoadedID3Tag
    func save(_ loaded: LoadedID3Tag, draft: ID3TagDraft) async throws -> LoadedID3Tag
}

struct LoadedID3Tag: Sendable {
    let url: URL
    let source: AudioFileInfo
    let draft: ID3TagDraft
    let hadID3v2Tag: Bool
    let snapshot: AudioFileSnapshot
}

struct AudioFileSnapshot: Equatable, Sendable {
    let fileSize: Int
    let modificationDate: Date?
    let tagFingerprint: Data
}

actor ID3MetadataService: ID3MetadataServicing {
    func load(from url: URL) async throws -> LoadedID3Tag {
        guard url.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame else {
            throw ID3TagServiceError.notAnMP3
        }

        let snapshotBeforeRead = try snapshot(of: url)
        let loaded: LoadedID3Tag

        switch try tagState(at: url) {
        case .none:
            let source = AudioFileInfo()
            loaded = LoadedID3Tag(
                url: url,
                source: source,
                draft: makeDraft(from: source.metadata),
                hadID3v2Tag: false,
                snapshot: snapshotBeforeRead
            )

        case .supported:
            do {
                let source = try ID3Reader().read(from: url)
                loaded = LoadedID3Tag(
                    url: url,
                    source: source,
                    draft: makeDraft(from: source.metadata),
                    hadID3v2Tag: true,
                    snapshot: snapshotBeforeRead
                )
            } catch {
                throw ID3TagServiceError.corruptTag(error.localizedDescription)
            }
        }

        guard try snapshot(of: url) == snapshotBeforeRead else {
            throw ID3TagServiceError.fileChangedExternally
        }

        return loaded
    }

    func save(
        _ loaded: LoadedID3Tag,
        draft: ID3TagDraft
    ) async throws -> LoadedID3Tag {
        let url = loaded.url
        guard try snapshot(of: url) == loaded.snapshot else {
            throw ID3TagServiceError.fileChangedExternally
        }

        let currentState = try tagState(at: url)

        if loaded.hadID3v2Tag, currentState == .none {
            throw ID3TagServiceError.fileChangedExternally
        }

        if !loaded.hadID3v2Tag, currentState == .supported {
            throw ID3TagServiceError.fileChangedExternally
        }

        if loaded.hadID3v2Tag {
            do {
                _ = try ID3Reader().readRawFrames(from: url)
            } catch {
                throw ID3TagServiceError.corruptTag(error.localizedDescription)
            }
        }

        var updated = loaded.source
        try apply(draft, to: &updated)

        do {
            if loaded.hadID3v2Tag {
                // A nil version preserves an existing v2.3 or v2.4 tag version.
                try ID3Writer().modify(updated, in: url, version: nil)
            } else {
                try ID3Writer().write(updated, to: url, version: .v2_3)
            }
        } catch {
            throw ID3TagServiceError.writeFailed(error.localizedDescription)
        }

        return try await load(from: url)
    }

    private enum TagState: Equatable {
        case none
        case supported
    }

    private func tagState(at url: URL) throws -> TagState {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ID3TagServiceError.cannotRead(error.localizedDescription)
        }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: 10) ?? Data()
        } catch {
            throw ID3TagServiceError.cannotRead(error.localizedDescription)
        }

        let bytes = Array(header.prefix(5))
        guard bytes.count >= 3,
              bytes[0] == 0x49,
              bytes[1] == 0x44,
              bytes[2] == 0x33 else {
            return .none
        }

        guard bytes.count >= 5 else {
            throw ID3TagServiceError.corruptTag("The ID3 header is incomplete.")
        }

        switch bytes[3] {
        case 3, 4:
            return .supported
        case 2:
            throw ID3TagServiceError.unsupportedVersion("ID3v2.2")
        default:
            throw ID3TagServiceError.unsupportedVersion("ID3v2.\(bytes[3])")
        }
    }

    private func snapshot(of url: URL) throws -> AudioFileSnapshot {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let fileSize = (attributes[.size] as? NSNumber)?.intValue else {
                throw ID3TagServiceError.cannotRead("The file size is unavailable.")
            }
            return AudioFileSnapshot(
                fileSize: fileSize,
                modificationDate: attributes[.modificationDate] as? Date,
                tagFingerprint: try tagFingerprint(of: url, fileSize: fileSize)
            )
        } catch let error as ID3TagServiceError {
            throw error
        } catch {
            throw ID3TagServiceError.cannotRead(error.localizedDescription)
        }
    }

    private func tagFingerprint(of url: URL, fileSize: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ID3TagServiceError.cannotRead(error.localizedDescription)
        }
        defer { try? handle.close() }

        do {
            let header = try handle.read(upToCount: 10) ?? Data()
            var hasher = SHA256()
            hasher.update(data: header)

            guard header.count == 10,
                  header.starts(with: [0x49, 0x44, 0x33]) else {
                return Data(hasher.finalize())
            }

            let bytes = [UInt8](header)
            let declaredTagSize = bytes[6...9].reduce(0) { partial, byte in
                (partial << 7) | Int(byte & 0x7F)
            }
            guard declaredTagSize <= fileSize - 10 else {
                return Data(hasher.finalize())
            }

            var remaining = declaredTagSize
            while remaining > 0 {
                let chunkSize = min(remaining, 1_048_576)
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                remaining -= chunk.count
            }

            return Data(hasher.finalize())
        } catch let error as ID3TagServiceError {
            throw error
        } catch {
            throw ID3TagServiceError.cannotRead(error.localizedDescription)
        }
    }

    private func makeDraft(from metadata: AudioMetadata) -> ID3TagDraft {
        ID3TagDraft(
            title: metadata.title ?? "",
            artist: metadata.artist ?? "",
            album: metadata.album ?? "",
            albumArtist: metadata.albumArtist ?? "",
            trackNumber: metadata.trackNumber.map(String.init) ?? "",
            discNumber: metadata.discNumber.map(String.init) ?? "",
            year: metadata.year.map(String.init) ?? "",
            genre: metadata.genre ?? "",
            composer: metadata.composer ?? "",
            comment: metadata.comment ?? "",
            lyrics: metadata.unsynchronizedLyrics ?? "",
            artworkData: metadata.artwork?.data
        )
    }

    private func apply(_ draft: ID3TagDraft, to info: inout AudioFileInfo) throws {
        let numbers = try draft.validatedNumbers()

        info.metadata.title = nilIfEmpty(draft.title)
        info.metadata.artist = nilIfEmpty(draft.artist)
        info.metadata.album = nilIfEmpty(draft.album)
        info.metadata.albumArtist = nilIfEmpty(draft.albumArtist)
        info.metadata.trackNumber = numbers.track
        info.metadata.discNumber = numbers.disc
        info.metadata.year = numbers.year
        info.metadata.genre = nilIfEmpty(draft.genre)
        info.metadata.composer = nilIfEmpty(draft.composer)
        info.metadata.comment = nilIfEmpty(draft.comment)
        info.metadata.unsynchronizedLyrics = nilIfEmpty(draft.lyrics)

        if let artworkData = draft.artworkData {
            do {
                info.metadata.artwork = try Artwork(data: artworkData)
            } catch {
                throw ID3TagServiceError.invalidArtwork
            }
        } else {
            info.metadata.artwork = nil
        }
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ID3TagServiceError: LocalizedError, Equatable {
    case notAnMP3
    case cannotRead(String)
    case corruptTag(String)
    case unsupportedVersion(String)
    case invalidArtwork
    case fileChangedExternally
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnMP3:
            return "Only MP3 files are supported in this version."
        case .cannotRead(let reason):
            return "The file could not be read: \(reason)"
        case .corruptTag(let reason):
            return "This file has an invalid ID3 tag. It was left unchanged. \(reason)"
        case .unsupportedVersion(let version):
            return "\(version) tags are not supported yet. The file was left unchanged."
        case .invalidArtwork:
            return "Artwork must be a valid JPEG or PNG image."
        case .fileChangedExternally:
            return "The file changed after it was opened. Reload it before saving."
        case .writeFailed(let reason):
            return "The tags could not be saved: \(reason)"
        }
    }
}
