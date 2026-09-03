import Darwin
import Foundation

protocol FileRenaming: Sendable {
    func validateRename(from source: URL, toFileName fileName: String) async throws -> URL
    func rename(from source: URL, to destination: URL) async throws
}

actor FileSystemService: FileRenaming {
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .fileSizeKey,
    ]

    func contents(of directory: URL) throws -> [DirectoryEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(urls.count)

        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: resourceKeys)

            guard values.isSymbolicLink != true, values.isPackage != true else {
                continue
            }

            if values.isDirectory == true {
                entries.append(
                    DirectoryEntry(
                        url: url.standardizedFileURL,
                        name: url.lastPathComponent,
                        kind: .folder,
                        fileSize: nil
                    )
                )
            } else if values.isRegularFile == true,
                      url.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame {
                entries.append(
                    DirectoryEntry(
                        url: url.standardizedFileURL,
                        name: url.lastPathComponent,
                        kind: .mp3,
                        fileSize: values.fileSize
                    )
                )
            }
        }

        return entries.sorted(by: DirectoryEntry.areInDisplayOrder)
    }

    func childFolders(of directory: URL) throws -> [FolderItem] {
        try contents(of: directory)
            .filter { $0.kind == .folder }
            .map { FolderItem(url: $0.url, name: $0.name) }
    }

    func validateRename(
        from source: URL,
        toFileName fileName: String
    ) throws -> URL {
        let source = source.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: source.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw FileRenameError.sourceMissing(source.lastPathComponent)
        }

        let sourceValues: URLResourceValues
        do {
            sourceValues = try source.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw FileRenameError.sourceUnavailable(source.lastPathComponent)
        }
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              source.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame else {
            throw FileRenameError.sourceUnavailable(source.lastPathComponent)
        }

        let fileNameURL = URL(fileURLWithPath: fileName)
        let stem = fileNameURL.deletingPathExtension().lastPathComponent
        guard fileNameURL.lastPathComponent == fileName,
              fileNameURL.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame,
              FilenameDraft.validationMessage(for: stem) == nil else {
            throw FileRenameError.invalidFileName
        }

        let parent = source.deletingLastPathComponent().standardizedFileURL
        if exceedsNameLimit(fileName, in: parent) {
            throw FileRenameError.fileNameTooLong
        }

        let destination = parent
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard destination.deletingLastPathComponent() == parent else {
            throw FileRenameError.invalidFileName
        }

        if destination == source {
            return destination
        }

        if directoryEntryExists(at: destination),
           !isCaseOnlyReferenceToSource(source, destination) {
            throw FileRenameError.destinationExists(fileName)
        }

        return destination
    }

    func rename(from source: URL, to destination: URL) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let validatedDestination = try validateRename(
            from: source,
            toFileName: destination.lastPathComponent
        )
        guard validatedDestination == destination else {
            throw FileRenameError.invalidFileName
        }

        guard source != destination else { return }

        do {
            // FileManager performs case-only renames atomically on macOS file
            // systems that expose both spellings as the same directory entry.
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw FileRenameError.renameFailed(error.localizedDescription)
        }
    }

    private func isCaseOnlyReferenceToSource(_ source: URL, _ destination: URL) -> Bool {
        guard source.lastPathComponent != destination.lastPathComponent,
              source.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame,
              let isCaseSensitive = try? source.deletingLastPathComponent().resourceValues(
                  forKeys: [.volumeSupportsCaseSensitiveNamesKey]
              ).volumeSupportsCaseSensitiveNames,
              isCaseSensitive == false else {
            return false
        }

        // On a case-insensitive volume, two names that differ only by case
        // cannot be distinct directory entries in the same parent folder.
        return true
    }

    private func exceedsNameLimit(_ fileName: String, in directory: URL) -> Bool {
        let maximumLength = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return pathconf(path, _PC_NAME_MAX)
        }

        guard maximumLength > 0 else { return false }
        return fileName.lengthOfBytes(using: .utf8) > maximumLength
    }

    private func directoryEntryExists(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var information = stat()
            return lstat(path, &information) == 0
        }
    }
}

enum FileRenameError: LocalizedError, Equatable {
    case sourceMissing(String)
    case sourceUnavailable(String)
    case invalidFileName
    case fileNameTooLong
    case destinationExists(String)
    case renameFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let fileName):
            return "“\(fileName)” can’t be found. Refresh the folder and try again."
        case .sourceUnavailable(let fileName):
            return "“\(fileName)” is no longer a regular MP3 file. Refresh the folder and try again."
        case .invalidFileName:
            return "Choose a valid MP3 file name."
        case .fileNameTooLong:
            return "The file name is too long for this folder. Shorten it and try again."
        case .destinationExists(let fileName):
            return "A file named “\(fileName)” already exists in this folder."
        case .renameFailed(let reason):
            return "The file couldn’t be renamed. \(reason)"
        }
    }
}
