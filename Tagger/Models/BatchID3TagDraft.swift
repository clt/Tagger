import Foundation

enum BatchFieldSource<Value: Equatable & Sendable>: Equatable, Sendable {
    case shared(Value)
    case mixed

    init(values: [Value]) {
        guard let first = values.first,
              values.dropFirst().allSatisfy({ $0 == first }) else {
            self = .mixed
            return
        }

        self = .shared(first)
    }
}

enum BatchFieldEdit<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)
    case clear
}

struct BatchTextFieldDraft: Equatable, Sendable {
    let source: BatchFieldSource<String>
    var edit: BatchFieldEdit<String>

    init(values: [String]) {
        source = BatchFieldSource(values: values)
        edit = .unchanged
    }

    var isApplied: Bool {
        get { edit != .unchanged }
        set {
            if newValue {
                guard edit == .unchanged else { return }
                let sourceText = source.sharedValue ?? ""
                edit = sourceText.isEmpty ? .clear : .set(sourceText)
            } else {
                edit = .unchanged
            }
        }
    }

    var text: String {
        get {
            switch edit {
            case .unchanged:
                return source.sharedValue ?? ""
            case .set(let value):
                return value
            case .clear:
                return ""
            }
        }
        set {
            edit = newValue.isEmpty ? .clear : .set(newValue)
        }
    }

    var placeholder: String {
        if edit == .unchanged, source == .mixed {
            return "Mixed Values"
        }
        return ""
    }

    func applying(to original: String) -> String {
        switch edit {
        case .unchanged:
            return original
        case .set(let value):
            return value
        case .clear:
            return ""
        }
    }
}

enum BatchArtworkEdit: Equatable, Sendable {
    case unchanged
    case replace(Data)
    case remove
}

struct BatchArtworkFieldDraft: Equatable, Sendable {
    let source: BatchFieldSource<Data?>
    var edit: BatchArtworkEdit

    init(values: [Data?]) {
        source = BatchFieldSource(values: values)
        edit = .unchanged
    }

    var isApplied: Bool {
        get { edit != .unchanged }
        set {
            if newValue {
                guard edit == .unchanged else { return }
                if let sourceData = source.sharedValue ?? nil {
                    edit = .replace(sourceData)
                } else {
                    edit = .remove
                }
            } else {
                edit = .unchanged
            }
        }
    }

    var data: Data? {
        get {
            switch edit {
            case .unchanged:
                return source.sharedValue ?? nil
            case .replace(let data):
                return data
            case .remove:
                return nil
            }
        }
        set {
            if let newValue {
                edit = .replace(newValue)
            } else {
                edit = .remove
            }
        }
    }

    mutating func replace(with data: Data) {
        edit = .replace(data)
    }

    mutating func remove() {
        edit = .remove
    }

    func applying(to original: Data?) -> Data? {
        switch edit {
        case .unchanged:
            return original
        case .replace(let data):
            return data
        case .remove:
            return nil
        }
    }
}

struct BatchID3TagDraft: Equatable, Sendable {
    var title: BatchTextFieldDraft
    var artist: BatchTextFieldDraft
    var album: BatchTextFieldDraft
    var albumArtist: BatchTextFieldDraft
    var trackNumber: BatchTextFieldDraft
    var discNumber: BatchTextFieldDraft
    var year: BatchTextFieldDraft
    var genre: BatchTextFieldDraft
    var composer: BatchTextFieldDraft
    var comment: BatchTextFieldDraft
    var lyrics: BatchTextFieldDraft
    var artworkData: BatchArtworkFieldDraft

    init(drafts: [ID3TagDraft]) {
        title = BatchTextFieldDraft(values: drafts.map(\.title))
        artist = BatchTextFieldDraft(values: drafts.map(\.artist))
        album = BatchTextFieldDraft(values: drafts.map(\.album))
        albumArtist = BatchTextFieldDraft(values: drafts.map(\.albumArtist))
        trackNumber = BatchTextFieldDraft(values: drafts.map(\.trackNumber))
        discNumber = BatchTextFieldDraft(values: drafts.map(\.discNumber))
        year = BatchTextFieldDraft(values: drafts.map(\.year))
        genre = BatchTextFieldDraft(values: drafts.map(\.genre))
        composer = BatchTextFieldDraft(values: drafts.map(\.composer))
        comment = BatchTextFieldDraft(values: drafts.map(\.comment))
        lyrics = BatchTextFieldDraft(values: drafts.map(\.lyrics))
        artworkData = BatchArtworkFieldDraft(values: drafts.map(\.artworkData))
    }

    var isDirty: Bool {
        title.isApplied
            || artist.isApplied
            || album.isApplied
            || albumArtist.isApplied
            || trackNumber.isApplied
            || discNumber.isApplied
            || year.isApplied
            || genre.isApplied
            || composer.isApplied
            || comment.isApplied
            || lyrics.isApplied
            || artworkData.isApplied
    }

    var validationMessage: String? {
        var appliedNumbers = ID3TagDraft()

        if trackNumber.isApplied {
            appliedNumbers.trackNumber = trackNumber.text
        }
        if discNumber.isApplied {
            appliedNumbers.discNumber = discNumber.text
        }
        if year.isApplied {
            appliedNumbers.year = year.text
        }

        return appliedNumbers.validationMessage
    }

    func applying(to original: ID3TagDraft) -> ID3TagDraft {
        var updated = original
        updated.title = title.applying(to: original.title)
        updated.artist = artist.applying(to: original.artist)
        updated.album = album.applying(to: original.album)
        updated.albumArtist = albumArtist.applying(to: original.albumArtist)
        updated.trackNumber = trackNumber.applying(to: original.trackNumber)
        updated.discNumber = discNumber.applying(to: original.discNumber)
        updated.year = year.applying(to: original.year)
        updated.genre = genre.applying(to: original.genre)
        updated.composer = composer.applying(to: original.composer)
        updated.comment = comment.applying(to: original.comment)
        updated.lyrics = lyrics.applying(to: original.lyrics)
        updated.artworkData = artworkData.applying(to: original.artworkData)
        return updated
    }

    func rebased(on drafts: [ID3TagDraft]) -> BatchID3TagDraft {
        var rebased = BatchID3TagDraft(drafts: drafts)
        rebased.title.edit = title.edit
        rebased.artist.edit = artist.edit
        rebased.album.edit = album.edit
        rebased.albumArtist.edit = albumArtist.edit
        rebased.trackNumber.edit = trackNumber.edit
        rebased.discNumber.edit = discNumber.edit
        rebased.year.edit = year.edit
        rebased.genre.edit = genre.edit
        rebased.composer.edit = composer.edit
        rebased.comment.edit = comment.edit
        rebased.lyrics.edit = lyrics.edit
        rebased.artworkData.edit = artworkData.edit
        return rebased
    }
}

private extension BatchFieldSource {
    var sharedValue: Value? {
        guard case .shared(let value) = self else { return nil }
        return value
    }
}
