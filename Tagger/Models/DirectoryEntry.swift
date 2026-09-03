import Foundation

struct FolderItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String

    var id: URL { url }
}

struct DirectoryEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case folder
        case mp3
    }

    let url: URL
    let name: String
    let kind: Kind
    let fileSize: Int?

    var id: URL { url }
}
