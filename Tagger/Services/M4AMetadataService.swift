import AudioMarker
import CryptoKit
import Darwin
import Foundation

/// Edits iTunes-style metadata without exporting or re-encoding the audio.
actor M4AMetadataService: ID3MetadataServicing {
    // Parsing and verification use bounded in-memory copies of the container.
    private static let maximumFileSize = 512 * 1_024 * 1_024

    func load(from url: URL) async throws -> LoadedID3Tag {
        let file = try readFile(at: url)
        let container = try M4AContainer(data: file.data)
        return loadedTag(at: url, draft: container.draft, snapshot: file.snapshot)
    }

    func validateUnchanged(_ loaded: LoadedID3Tag) async throws {
        guard try readFile(at: loaded.url).snapshot == loaded.snapshot else {
            throw ID3TagServiceError.fileChangedExternally
        }
    }

    func save(_ loaded: LoadedID3Tag, draft: ID3TagDraft) async throws -> LoadedID3Tag {
        let original = try readFile(at: loaded.url)
        guard original.snapshot == loaded.snapshot else {
            throw ID3TagServiceError.fileChangedExternally
        }
        let container = try M4AContainer(data: original.data)
        let updated = try container.updating(to: draft)
        guard updated.count <= Self.maximumFileSize else {
            throw M4AMetadataServiceError.fileTooLarge
        }
        let verified = try M4AContainer(data: updated)
        guard verified.audioPayloads == container.audioPayloads else {
            throw M4AMetadataServiceError.audioVerificationFailed
        }
        try Task.checkCancellation()

        if updated == original.data {
            return loadedTag(at: loaded.url, draft: verified.draft, snapshot: original.snapshot)
        }

        let temporary = loaded.url.deletingLastPathComponent()
            .appendingPathComponent(".tagger-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            // Copying first keeps permissions, extended attributes, and creation date.
            try FileManager.default.copyItem(at: loaded.url, to: temporary)
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw posixError() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                var attributes = stat()
                guard fstat(descriptor, &attributes) == 0,
                      attributes.st_mode & S_IFMT == S_IFREG,
                      attributes.st_nlink == 1 else {
                    throw M4AMetadataServiceError.unsafeFile
                }
                try handle.write(contentsOf: updated)
                try handle.truncate(atOffset: UInt64(updated.count))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            let staged = try readFile(at: temporary)
            guard staged.data == updated else {
                throw M4AMetadataServiceError.writeVerificationFailed
            }
            try Task.checkCancellation()

            // Recheck the original immediately before the only operation that replaces it.
            let current = try readFile(at: loaded.url)
            guard current.snapshot == loaded.snapshot,
                  sameVersion(original.attributes, current.attributes) else {
                throw ID3TagServiceError.fileChangedExternally
            }
            guard Darwin.rename(temporary.path, loaded.url.path) == 0 else {
                throw posixError()
            }

            // The staged inode and bytes survive rename. Return its verified snapshot
            // without a fallible post-write reload that could misreport a successful save.
            return loadedTag(at: loaded.url, draft: verified.draft, snapshot: staged.snapshot)
        } catch let error as ID3TagServiceError {
            throw error
        } catch let error as M4AMetadataServiceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ID3TagServiceError.writeFailed(error.localizedDescription)
        }
    }

    private func loadedTag(
        at url: URL, draft: ID3TagDraft, snapshot: AudioFileSnapshot
    ) -> LoadedID3Tag {
        LoadedID3Tag(
            url: url,
            source: AudioFileInfo(), // Only the MP3 backend uses the ID3 source model.
            draft: draft,
            hadID3v2Tag: false,
            snapshot: snapshot
        )
    }

    private struct FileContents {
        let data: Data
        let snapshot: AudioFileSnapshot
        let attributes: stat
    }

    private func readFile(at url: URL) throws -> FileContents {
        guard url.isFileURL, url.pathExtension.lowercased() == "m4a" else {
            throw AudioMetadataServiceError.unsupportedFormat
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw M4AMetadataServiceError.unsafeFile }
            throw ID3TagServiceError.cannotRead(posixError().localizedDescription)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError() }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw M4AMetadataServiceError.unsafeFile
        }
        guard before.st_size >= 0, before.st_size <= Self.maximumFileSize else {
            throw M4AMetadataServiceError.fileTooLarge
        }

        let expectedSize = Int(before.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var fingerprint = SHA256()
        while data.count <= expectedSize {
            try Task.checkCancellation()
            let count = min(1_048_576, expectedSize + 1 - data.count)
            let chunk = try handle.read(upToCount: count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            fingerprint.update(data: chunk)
        }

        var after = stat()
        var pathAttributes = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAttributes) == 0,
              data.count == expectedSize,
              sameVersion(before, after),
              sameVersion(after, pathAttributes) else {
            throw ID3TagServiceError.fileChangedExternally
        }
        return FileContents(
            data: data,
            snapshot: AudioFileSnapshot(
                fileSize: expectedSize,
                modificationDate: Date(
                    timeIntervalSince1970: Double(after.st_mtimespec.tv_sec)
                        + Double(after.st_mtimespec.tv_nsec) / 1_000_000_000
                ),
                tagFingerprint: Data(fingerprint.finalize()),
                fileIdentity: "\(after.st_dev):\(after.st_ino)"
            ),
            attributes: after
        )
    }

    private func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

enum M4AMetadataServiceError: LocalizedError {
    case unsafeFile
    case fileTooLarge
    case audioVerificationFailed
    case writeVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unsafeFile:
            "Choose a regular M4A file, rather than a symbolic link or a file with multiple hard links."
        case .fileTooLarge:
            "M4A files must be 512 MB or smaller in this version. The file was left unchanged."
        case .audioVerificationFailed:
            "The M4A audio could not be preserved. The file was left unchanged."
        case .writeVerificationFailed:
            "The new M4A tags could not be verified. The file was left unchanged."
        }
    }
}
