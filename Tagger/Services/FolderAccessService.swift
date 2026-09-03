import Foundation

@MainActor
final class FolderAccessService {
    private let bookmarkKey = "Tagger.lastFolderBookmark"
    private var activeURL: URL?
    private var didStartAccess = false

    deinit {
        if didStartAccess {
            activeURL?.stopAccessingSecurityScopedResource()
        }
    }

    func beginAccessing(_ url: URL) throws {
        stopAccessingCurrentFolder()

        activeURL = url
        didStartAccess = url.startAccessingSecurityScopedResource()

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    func restoreLastFolder() throws -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        stopAccessingCurrentFolder()
        activeURL = url
        didStartAccess = url.startAccessingSecurityScopedResource()

        if isStale {
            let refreshedBookmark = try url.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           )
            UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
        }

        return url
    }

    func forgetLastFolder() {
        stopAccessingCurrentFolder()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private func stopAccessingCurrentFolder() {
        if didStartAccess {
            activeURL?.stopAccessingSecurityScopedResource()
        }
        activeURL = nil
        didStartAccess = false
    }
}
