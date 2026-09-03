import Foundation

actor FileSystemService {
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

        return entries.sorted(by: entrySort)
    }

    func childFolders(of directory: URL) throws -> [FolderItem] {
        try contents(of: directory)
            .filter { $0.kind == .folder }
            .map { FolderItem(url: $0.url, name: $0.name) }
    }

    private func entrySort(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .folder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
