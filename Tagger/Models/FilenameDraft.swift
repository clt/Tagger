import Foundation

struct FilenameDraft: Equatable, Sendable {
    let originalStem: String
    let pathExtension: String
    var stem: String

    init(url: URL) {
        originalStem = url.deletingPathExtension().lastPathComponent
        pathExtension = url.pathExtension
        stem = originalStem
    }

    var extensionSuffix: String {
        pathExtension.isEmpty ? "" : ".\(pathExtension)"
    }

    var originalFilename: String {
        originalStem + extensionSuffix
    }

    var proposedFilename: String {
        stem + extensionSuffix
    }

    var isDirty: Bool {
        stem != originalStem
    }

    var validationMessage: String? {
        guard isDirty else { return nil }
        return Self.validationMessage(for: stem)
    }

    mutating func revert() {
        stem = originalStem
    }

    static func validationMessage(for stem: String) -> String? {
        if stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "File name can’t be empty."
        }

        if stem == "." || stem == ".." {
            return "File name can’t be “.” or “..”."
        }

        if stem.hasPrefix(".") {
            return "File name can’t begin with a period because hidden files aren’t shown."
        }

        if stem.contains("/") || stem.contains(":") {
            return "File name can’t contain “/” or “:”."
        }

        let lineBreaksAndControls = CharacterSet.controlCharacters.union(.newlines)
        if stem.unicodeScalars.contains(where: lineBreaksAndControls.contains) {
            return "File name can’t contain line breaks or control characters."
        }

        return nil
    }
}
