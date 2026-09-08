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
        case m4a

        init?(audioPathExtension: String) {
            switch audioPathExtension.lowercased() {
            case "mp3": self = .mp3
            case "m4a": self = .m4a
            default: return nil
            }
        }
    }

    let url: URL
    let name: String
    let kind: Kind
    let fileSize: Int?

    var id: URL { url }
    var isAudioFile: Bool { kind == .mp3 || kind == .m4a }

    static func areInDisplayOrder(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        if (lhs.kind == .folder) != (rhs.kind == .folder) {
            return lhs.kind == .folder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
