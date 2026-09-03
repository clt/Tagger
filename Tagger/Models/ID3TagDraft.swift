import Foundation

struct ID3TagDraft: Equatable, Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var trackNumber = ""
    var discNumber = ""
    var year = ""
    var genre = ""
    var composer = ""
    var comment = ""
    var lyrics = ""
    var artworkData: Data?

    var validationMessage: String? {
        do {
            _ = try validatedNumbers()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func validatedNumbers() throws -> (track: Int?, disc: Int?, year: Int?) {
        let track = try positiveInteger(trackNumber, field: "Track number")
        let disc = try positiveInteger(discNumber, field: "Disc number")
        let parsedYear = try positiveInteger(year, field: "Year")

        if let parsedYear, parsedYear > 9_999 {
            throw TagDraftValidationError.invalidYear
        }

        return (track, disc, parsedYear)
    }

    private func positiveInteger(_ value: String, field: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let result = Int(trimmed), result > 0 else {
            throw TagDraftValidationError.invalidPositiveInteger(field)
        }
        return result
    }
}

enum TagDraftValidationError: LocalizedError, Equatable {
    case invalidPositiveInteger(String)
    case invalidYear

    var errorDescription: String? {
        switch self {
        case .invalidPositiveInteger(let field):
            return "\(field) must be a whole number greater than zero."
        case .invalidYear:
            return "Year must contain no more than four digits."
        }
    }
}
