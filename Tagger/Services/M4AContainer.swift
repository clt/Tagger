import AudioMarker
import Foundation

/// A conservative, in-memory editor for ordinary, self-contained AAC/ALAC M4A files.
/// Unchanged atoms are copied verbatim. Media bytes and their absolute offsets never move.
struct M4AContainer: Sendable {
    private let source: Data
    private let top: [Atom]
    private let movie: Atom
    private let movieChildren: [Atom]
    private let userData: Atom?
    private let userDataChildren: [Atom]
    private let metadata: Atom?
    private let metadataChildren: [Atom]
    private let itemList: Atom?
    private let items: [Atom]
    let draft: ID3TagDraft

    var audioPayloads: [Data] {
        top.filter { $0.type == .mdat }.map { source.subdata(in: $0.payload) }
    }

    init(data: Data) throws {
        // Normalize Data indices; callers may have supplied a slice.
        let data = Data(data)
        let parser = Parser(data: data)
        let top = try parser.atoms(in: 0..<data.count)
        guard top.allSatisfy({ !$0.extendsToEnd }) else {
            throw M4AContainerError.unsupported("Atoms extending to the end of the file are not supported.")
        }
        let fileType = try parser.required(.ftyp, in: top)
        try parser.validateFileType(fileType)
        let movie = try parser.required(.moov, in: top)
        guard movie.range.count <= Self.maximumMetadataSize else {
            throw M4AContainerError.unsupported("The movie metadata is too large to edit safely.")
        }
        guard top.contains(where: { $0.type == .mdat && !$0.payload.isEmpty }) else {
            throw M4AContainerError.malformed("The audio data is missing.")
        }
        try parser.reject(top, types: [.moof, .mfra, .sidx, .ssix, .meta])
        let movieChildren = try parser.atoms(in: movie.payload)
        try parser.reject(movieChildren, types: [.mvex, .cmov, .meta, .saio, .senc])
        let tracks = movieChildren.filter { $0.type == .trak }
        guard !tracks.isEmpty, tracks.count <= 32 else {
            throw M4AContainerError.unsupported("An ordinary audio track is required.")
        }
        let mediaRanges = top.filter { $0.type == .mdat }.map(\.payload)
        for track in tracks {
            try parser.validateAudioTrack(track, mediaRanges: mediaRanges)
        }

        let userData = try parser.optional(.udta, in: movieChildren)
        let userDataChildren = try userData.map { try parser.atoms(in: $0.payload) } ?? []
        let metadata = try parser.optional(.meta, in: userDataChildren)
        let metadataChildren: [Atom]
        if let metadata {
            try parser.requireFullBoxZero(metadata, minimumPayload: 4)
            metadataChildren = try parser.atoms(in: (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound)
            if let handler = try parser.optional(.hdlr, in: metadataChildren) {
                guard handler.payload.count >= 12,
                      parser.uint32(at: handler.payload.lowerBound + 8) == FourCC.mdir.rawValue else {
                    throw M4AContainerError.unsupported("Only iTunes-style M4A metadata is supported.")
                }
            }
            try parser.reject(metadataChildren, types: [.keys, .iloc, .iinf])
        } else {
            metadataChildren = []
        }
        let itemList = try parser.optional(.ilst, in: metadataChildren)
        let items = try itemList.map { try parser.atoms(in: $0.payload) } ?? []
        var draft = ID3TagDraft()
        for field in TextField.allCases {
            if let value = try parser.textValue(type: field.type, items: items) {
                draft[keyPath: field.keyPath] = value
            }
        }
        if draft.genre.isEmpty, let item = items.first(where: { $0.type == .gnre }) {
            if let value = try parser.dataValue(in: item) {
                guard value.bytes.count == 2, value.kind == 0 || value.kind == 21 else {
                    throw M4AContainerError.unsupported("The numeric genre encoding is not supported.")
                }
                let index = Int(value.bytes[0]) * 256 + Int(value.bytes[1])
                draft.genre = index > 0 && index <= Self.genreNames.count ? Self.genreNames[index - 1] : ""
            }
        }
        draft.trackNumber = try parser.numberValue(type: .trkn, items: items)
        draft.discNumber = try parser.numberValue(type: .disk, items: items)
        if let date = try parser.textValue(type: .day, items: items) {
            // Keep a full release date in its original atom until the Year field changes.
            let prefix = String(date.prefix(4))
            if let year = Int(prefix), year > 0, year <= 9_999 {
                draft.year = String(year)
            }
        }
        if let artwork = items.first(where: { $0.type == .covr }),
           let value = try parser.dataValue(in: artwork) {
            guard [0, 13, 14].contains(value.kind), value.bytes.count <= Self.maximumArtworkSize else {
                throw M4AContainerError.unsupported("The embedded artwork format or size is not supported.")
            }
            guard (try? Artwork(data: value.bytes)) != nil else {
                throw M4AContainerError.invalidArtwork
            }
            draft.artworkData = value.bytes
        }
        self.source = data
        self.top = top
        self.movie = movie
        self.movieChildren = movieChildren
        self.userData = userData
        self.userDataChildren = userDataChildren
        self.metadata = metadata
        self.metadataChildren = metadataChildren
        self.itemList = itemList
        self.items = items
        self.draft = draft
    }

    func updating(to updated: ID3TagDraft) throws -> Data {
        if updated == draft { return source }
        let numbers = try updated.validatedNumbers()
        guard (numbers.track ?? 0) <= 65_535, (numbers.disc ?? 0) <= 65_535 else {
            throw M4AContainerError.invalidValue("M4A track and disc numbers cannot exceed 65535.")
        }

        var replacements: [FourCC: Data] = [:]
        var changed: Set<FourCC> = []
        for field in TextField.allCases where updated[keyPath: field.keyPath] != draft[keyPath: field.keyPath] {
            let value = updated[keyPath: field.keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            changed.insert(field.type)
            if field == .genre { changed.insert(.gnre) }
            if !value.isEmpty {
                guard value.utf8.count <= Self.maximumTextSize, !value.contains("\0") else {
                    throw M4AContainerError.invalidValue("A text field is too large or contains a null character.")
                }
                replacements[field.type] = try Self.item(field.type, kind: 1, bytes: Data(value.utf8))
            }
        }
        if updated.year != draft.year {
            changed.insert(.day)
            if let year = numbers.year {
                replacements[.day] = try Self.item(.day, kind: 1, bytes: Data(String(year).utf8))
            }
        }
        let parser = Parser(data: source)
        for (type, oldValue, newValue, number) in [
            (FourCC.trkn, draft.trackNumber, updated.trackNumber, numbers.track),
            (FourCC.disk, draft.discNumber, updated.discNumber, numbers.disc)
        ] where oldValue != newValue {
            changed.insert(type)
            var bytes = Data(repeating: 0, count: type == .trkn ? 8 : 6)
            if let oldItem = items.first(where: { $0.type == type }),
               let oldData = try parser.dataValue(in: oldItem) {
                bytes = oldData.bytes
            }
            // Zero represents a blank number. Keep totals and reserved bytes
            // even when clearing the number exposed in the editor.
            bytes[2] = UInt8((number ?? 0) >> 8)
            bytes[3] = UInt8((number ?? 0) & 255)
            if number != nil || bytes.contains(where: { $0 != 0 }) {
                replacements[type] = try Self.item(type, kind: 0, bytes: bytes)
            }
        }
        if updated.artworkData != draft.artworkData {
            changed.insert(.covr)
            if let artwork = updated.artworkData {
                guard artwork.count <= Self.maximumArtworkSize,
                      (try? Artwork(data: artwork)) != nil else {
                    throw M4AContainerError.invalidArtwork
                }
                let kind: UInt32 = artwork.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? 14 : 13
                replacements[.covr] = try Self.item(.covr, kind: kind, bytes: artwork)
            }
        }

        var itemBytes = Data()
        var written: Set<FourCC> = []
        for item in items {
            if changed.contains(item.type) {
                if written.insert(item.type).inserted, let replacement = replacements[item.type] {
                    itemBytes.append(replacement)
                }
            } else {
                itemBytes.append(source.subdata(in: item.range))
            }
        }
        for type in changed.sorted(by: { $0.rawValue < $1.rawValue }) where !written.contains(type) {
            if let replacement = replacements[type] { itemBytes.append(replacement) }
        }
        let newList = try Self.atom(.ilst, payload: itemBytes)
        var newMetadataPayload = Data(repeating: 0, count: 4)
        if metadata == nil {
            // FullBox, predefined, handler type, three reserved words, empty name.
            var handler = Data(repeating: 0, count: 8)
            handler.append(Self.bigEndian(FourCC.mdir.rawValue))
            handler.append(Data(repeating: 0, count: 13))
            newMetadataPayload.append(try Self.atom(.hdlr, payload: handler))
        }
        newMetadataPayload.append(replacing(itemList, with: newList, in: metadataChildren))
        let newMetadata = try Self.atom(.meta, payload: newMetadataPayload)
        let newUserData = try Self.atom(.udta, payload: replacing(metadata, with: newMetadata, in: userDataChildren))
        let newMovie = try Self.atom(.moov, payload: replacing(userData, with: newUserData, in: movieChildren))
        guard newMovie.count <= Self.maximumMetadataSize else {
            throw M4AContainerError.invalidValue("The updated metadata is too large.")
        }

        var result = source
        if movie.range.upperBound == source.count {
            result.replaceSubrange(movie.range, with: newMovie)
        } else {
            // stco/co64 contain absolute offsets. Leave every pre-existing media
            // location intact, replacing the old moov with an equally sized free atom.
            let free = try Self.atom(.free, payload: Data(repeating: 0, count: movie.range.count - 8))
            result.replaceSubrange(movie.range, with: free)
            result.append(newMovie)
        }
        // Validate the complete candidate before any caller can write it.
        _ = try M4AContainer(data: result)
        return result
    }

    private func replacing(_ target: Atom?, with replacement: Data, in children: [Atom]) -> Data {
        var result = Data()
        for child in children {
            result.append(child.range == target?.range ? replacement : source.subdata(in: child.range))
        }
        if target == nil { result.append(replacement) }
        return result
    }

    private static let maximumMetadataSize = 64 * 1_024 * 1_024
    private static let maximumArtworkSize = 32 * 1_024 * 1_024
    private static let maximumTextSize = 1_024 * 1_024

    private static func atom(_ type: FourCC, payload: Data) throws -> Data {
        guard payload.count <= maximumMetadataSize, payload.count <= Int(UInt32.max) - 8 else {
            throw M4AContainerError.invalidValue("An updated metadata atom is too large.")
        }
        var data = bigEndian(UInt32(payload.count + 8))
        data.append(bigEndian(type.rawValue))
        data.append(payload)
        return data
    }

    private static func item(_ type: FourCC, kind: UInt32, bytes: Data) throws -> Data {
        var value = bigEndian(kind)
        value.append(Data(repeating: 0, count: 4))
        value.append(bytes)
        return try atom(type, payload: atom(.data, payload: value))
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    private enum TextField: CaseIterable {
        case title, artist, album, albumArtist, genre, composer, comment, lyrics

        var type: FourCC {
            switch self {
            case .title: .nam
            case .artist: .art
            case .album: .alb
            case .albumArtist: .aart
            case .genre: .gen
            case .composer: .wrt
            case .comment: .cmt
            case .lyrics: .lyr
            }
        }

        var keyPath: WritableKeyPath<ID3TagDraft, String> {
            switch self {
            case .title: \.title
            case .artist: \.artist
            case .album: \.album
            case .albumArtist: \.albumArtist
            case .genre: \.genre
            case .composer: \.composer
            case .comment: \.comment
            case .lyrics: \.lyrics
            }
        }
    }

    private struct Atom: Sendable {
        let type: FourCC
        let range: Range<Int>
        let payload: Range<Int>
        let extendsToEnd: Bool
    }

    private struct Parser {
        let data: Data

        func atoms(in range: Range<Int>) throws -> [Atom] {
            guard range.lowerBound >= 0, range.upperBound <= data.count else {
                throw M4AContainerError.malformed("An atom extends outside its parent.")
            }
            var result: [Atom] = []
            var position = range.lowerBound
            while position < range.upperBound {
                guard range.upperBound - position >= 8, result.count < 100_000 else {
                    throw M4AContainerError.malformed("An atom header is truncated or there are too many atoms.")
                }
                let size32 = uint32(at: position)
                let type = FourCC(rawValue: uint32(at: position + 4))
                let header: Int
                let size: Int
                switch size32 {
                case 0:
                    header = 8
                    size = range.upperBound - position
                case 1:
                    guard range.upperBound - position >= 16 else {
                        throw M4AContainerError.malformed("An extended atom header is truncated.")
                    }
                    header = 16
                    let largeSize = uint64(at: position + 8)
                    guard largeSize <= UInt64(range.upperBound - position) else {
                        throw M4AContainerError.malformed("An extended atom size exceeds its parent.")
                    }
                    size = Int(largeSize)
                default:
                    header = 8
                    size = Int(size32)
                }
                guard size >= header, size <= range.upperBound - position else {
                    throw M4AContainerError.malformed("An atom has an invalid size.")
                }
                // Size-zero children become ambiguous if a sibling is appended later.
                guard size32 != 0 else {
                    throw M4AContainerError.unsupported("Atoms extending to the end of their parent are not supported.")
                }
                result.append(Atom(type: type, range: position..<(position + size),
                                   payload: (position + header)..<(position + size), extendsToEnd: size32 == 0))
                position += size
            }
            return result
        }

        func optional(_ type: FourCC, in atoms: [Atom]) throws -> Atom? {
            let matches = atoms.filter { $0.type == type }
            guard matches.count <= 1 else {
                throw M4AContainerError.unsupported("Duplicate structural atoms are not supported.")
            }
            return matches.first
        }

        func required(_ type: FourCC, in atoms: [Atom]) throws -> Atom {
            guard let result = try optional(type, in: atoms) else {
                throw M4AContainerError.malformed("A required audio container atom is missing.")
            }
            return result
        }

        func reject(_ atoms: [Atom], types: Set<FourCC>) throws {
            guard !atoms.contains(where: { types.contains($0.type) }) else {
                throw M4AContainerError.unsupported("Fragmented, protected, or nonstandard M4A layouts cannot be edited.")
            }
        }

        func requireFullBoxZero(_ atom: Atom, minimumPayload: Int) throws {
            guard atom.payload.count >= max(4, minimumPayload), uint32(at: atom.payload.lowerBound) == 0 else {
                throw M4AContainerError.malformed("An atom has an unsupported version, flags, or truncated payload.")
            }
        }

        func validateFileType(_ atom: Atom) throws {
            guard atom.payload.count >= 8, atom.payload.count <= 4_096, atom.payload.count % 4 == 0 else {
                throw M4AContainerError.malformed("The file type atom is incomplete.")
            }
            let supported: Set<UInt32> = [0x4d344120, 0x69736f6d, 0x69736f32, 0x6d703431, 0x6d703432]
            let brands = [uint32(at: atom.payload.lowerBound)] + stride(
                from: atom.payload.lowerBound + 8, to: atom.payload.upperBound, by: 4
            ).map { uint32(at: $0) }
            guard brands.contains(where: supported.contains) else {
                throw M4AContainerError.unsupported("This file is not a supported M4A audio container.")
            }
        }

        func validateAudioTrack(_ track: Atom, mediaRanges: [Range<Int>]) throws {
            let children = try atoms(in: track.payload)
            try reject(children, types: [.tref, .senc, .saio])
            let media = try required(.mdia, in: children)
            let mediaChildren = try atoms(in: media.payload)
            let handler = try required(.hdlr, in: mediaChildren)
            guard handler.payload.count >= 12,
                  uint32(at: handler.payload.lowerBound + 8) == FourCC.soun.rawValue else {
                throw M4AContainerError.unsupported("Only audio-only AAC and ALAC M4A files are supported.")
            }
            let mediaInfo = try required(.minf, in: mediaChildren)
            let infoChildren = try atoms(in: mediaInfo.payload)
            let dataInfo = try required(.dinf, in: infoChildren)
            let dataReference = try required(.dref, in: atoms(in: dataInfo.payload))
            try requireFullBoxZero(dataReference, minimumPayload: 8)
            let references = try atoms(in: (dataReference.payload.lowerBound + 8)..<dataReference.payload.upperBound)
            guard uint32(at: dataReference.payload.lowerBound + 4) == UInt32(references.count), !references.isEmpty else {
                throw M4AContainerError.malformed("The audio data references are incomplete.")
            }
            for reference in references {
                guard reference.type == .url, reference.payload.count == 4,
                      uint32(at: reference.payload.lowerBound) == 1 else {
                    throw M4AContainerError.unsupported("External or protected audio data references cannot be edited.")
                }
            }
            let table = try required(.stbl, in: infoChildren)
            let tables = try atoms(in: table.payload)
            try reject(tables, types: [.senc, .saio, .saiz, .stz2])
            let description = try required(.stsd, in: tables)
            try requireFullBoxZero(description, minimumPayload: 8)
            let entries = try atoms(in: (description.payload.lowerBound + 8)..<description.payload.upperBound)
            guard uint32(at: description.payload.lowerBound + 4) == UInt32(entries.count), !entries.isEmpty else {
                throw M4AContainerError.malformed("The audio sample descriptions are incomplete.")
            }
            for entry in entries {
                guard entry.type == .mp4a || entry.type == .alac else {
                    throw M4AContainerError.unsupported("Only unprotected AAC and ALAC audio can be edited.")
                }
                guard entry.payload.count >= 28 else {
                    throw M4AContainerError.malformed("An audio sample description is truncated.")
                }
                let version = uint16(at: entry.payload.lowerBound + 8)
                guard version == 0 else {
                    throw M4AContainerError.unsupported("This audio sample description version is not supported.")
                }
                let reference = Int(uint16(at: entry.payload.lowerBound + 6))
                guard reference > 0, reference <= references.count else {
                    throw M4AContainerError.malformed("An audio sample references missing data.")
                }
                let extensions = try atoms(in: (entry.payload.lowerBound + 28)..<entry.payload.upperBound)
                try reject(extensions, types: [.sinf, .schi, .senc])
                for nested in extensions where nested.type == .wave {
                    try reject(try atoms(in: nested.payload), types: [.sinf, .schi, .senc])
                }
            }
            let offsetTables = tables.filter { $0.type == .stco || $0.type == .co64 }
            guard offsetTables.count == 1, let offsets = offsetTables.first else {
                throw M4AContainerError.malformed("A single audio chunk offset table is required.")
            }
            try requireFullBoxZero(offsets, minimumPayload: 8)
            let count = Int(uint32(at: offsets.payload.lowerBound + 4))
            let width = offsets.type == .stco ? 4 : 8
            guard count > 0, offsets.payload.count - 8 == count * width else {
                throw M4AContainerError.malformed("The audio chunk offset table is truncated.")
            }
            let timing = try required(.stts, in: tables)
            let mapping = try required(.stsc, in: tables)
            let sizes = try required(.stsz, in: tables)
            for (atom, rowWidth) in [(timing, 8), (mapping, 12)] {
                try requireFullBoxZero(atom, minimumPayload: 8)
                let rows = Int(uint32(at: atom.payload.lowerBound + 4))
                guard rows > 0, atom.payload.count - 8 == rows * rowWidth else {
                    throw M4AContainerError.malformed("An audio sample table is truncated or empty.")
                }
            }
            try requireFullBoxZero(sizes, minimumPayload: 12)
            let fixedSize = UInt64(uint32(at: sizes.payload.lowerBound + 4))
            let sampleCount = UInt64(uint32(at: sizes.payload.lowerBound + 8))
            guard sampleCount > 0,
                  sizes.payload.count - 12 == (fixedSize == 0 ? Int(sampleCount) * 4 : 0) else {
                throw M4AContainerError.malformed("The audio sample size table is truncated or empty.")
            }
            var timedSamples: UInt64 = 0
            for position in stride(from: timing.payload.lowerBound + 8, to: timing.payload.upperBound, by: 8) {
                let samples = UInt64(uint32(at: position))
                guard samples > 0, uint32(at: position + 4) > 0 else {
                    throw M4AContainerError.malformed("An audio timing entry is invalid.")
                }
                timedSamples += samples
            }
            guard timedSamples == sampleCount else {
                throw M4AContainerError.malformed("The audio sample counts do not agree.")
            }
            var previousChunk: UInt32 = 0
            for position in stride(from: mapping.payload.lowerBound + 8, to: mapping.payload.upperBound, by: 12) {
                let firstChunk = uint32(at: position)
                let samples = uint32(at: position + 4)
                let description = uint32(at: position + 8)
                guard firstChunk > previousChunk, firstChunk <= UInt32(count),
                      (previousChunk != 0 || firstChunk == 1), samples > 0,
                      description > 0, description <= UInt32(entries.count) else {
                    throw M4AContainerError.malformed("An audio sample-to-chunk entry is invalid.")
                }
                previousChunk = firstChunk
            }
            var mappingPosition = mapping.payload.lowerBound + 8
            var consumedSamples: UInt64 = 0
            for index in 0..<count {
                if mappingPosition + 12 < mapping.payload.upperBound,
                   uint32(at: mappingPosition + 12) == UInt32(index + 1) {
                    mappingPosition += 12
                }
                let chunkSamples = UInt64(uint32(at: mappingPosition + 4))
                guard chunkSamples <= sampleCount - consumedSamples else {
                    throw M4AContainerError.malformed("A chunk references more samples than the file contains.")
                }
                var chunkBytes = fixedSize * chunkSamples
                if fixedSize == 0 {
                    for sample in consumedSamples..<(consumedSamples + chunkSamples) {
                        let sampleSize = UInt64(uint32(at: sizes.payload.lowerBound + 12 + Int(sample) * 4))
                        guard sampleSize > 0 else {
                            throw M4AContainerError.malformed("An audio sample has no data.")
                        }
                        chunkBytes += sampleSize
                    }
                }
                let location = offsets.payload.lowerBound + 8 + index * width
                let value = width == 4 ? UInt64(uint32(at: location)) : uint64(at: location)
                guard let range = containingMediaRange(value, in: mediaRanges),
                      chunkBytes <= UInt64(range.upperBound) - value else {
                    throw M4AContainerError.malformed("An audio chunk extends outside the audio data.")
                }
                consumedSamples += chunkSamples
            }
            guard consumedSamples == sampleCount else {
                throw M4AContainerError.malformed("The chunk table does not account for every audio sample.")
            }
        }

        private func containingMediaRange(_ offset: UInt64, in ranges: [Range<Int>]) -> Range<Int>? {
            // Top-level atoms are ordered and nonoverlapping. Avoid a quadratic
            // scan when an unusual file contains many media atoms and chunks.
            var lower = 0
            var upper = ranges.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let range = ranges[middle]
                if offset < UInt64(range.lowerBound) {
                    upper = middle
                } else if offset >= UInt64(range.upperBound) {
                    lower = middle + 1
                } else {
                    return range
                }
            }
            return nil
        }

        func dataValue(in item: Atom) throws -> (kind: UInt32, bytes: Data)? {
            let children = try atoms(in: item.payload)
            guard let value = children.first(where: { $0.type == .data }) else { return nil }
            guard value.payload.count >= 8 else {
                throw M4AContainerError.malformed("A metadata value is truncated.")
            }
            let kind = uint32(at: value.payload.lowerBound)
            guard kind >> 24 == 0 else {
                throw M4AContainerError.unsupported("This metadata value version is not supported.")
            }
            return (kind, data.subdata(in: (value.payload.lowerBound + 8)..<value.payload.upperBound))
        }

        func textValue(type: FourCC, items: [Atom]) throws -> String? {
            guard let item = items.first(where: { $0.type == type }),
                  let value = try dataValue(in: item) else { return nil }
            guard value.bytes.count <= M4AContainer.maximumTextSize else {
                throw M4AContainerError.unsupported("An embedded text value is too large.")
            }
            let encoding: String.Encoding
            switch value.kind {
            case 1: encoding = .utf8
            case 2: encoding = .utf16BigEndian
            default: throw M4AContainerError.unsupported("An embedded text encoding is not supported.")
            }
            guard let result = String(data: value.bytes, encoding: encoding) else {
                throw M4AContainerError.malformed("An embedded text value has invalid character encoding.")
            }
            return result.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }

        func numberValue(type: FourCC, items: [Atom]) throws -> String {
            guard let item = items.first(where: { $0.type == type }),
                  let value = try dataValue(in: item) else { return "" }
            guard value.kind == 0, value.bytes.count >= 6, value.bytes.count <= 8 else {
                throw M4AContainerError.malformed("A track or disc number is not a supported number pair.")
            }
            let number = Int(value.bytes[2]) * 256 + Int(value.bytes[3])
            return number == 0 ? "" : String(number)
        }

        func uint16(at position: Int) -> UInt16 {
            UInt16(data[position]) << 8 | UInt16(data[position + 1])
        }

        func uint32(at position: Int) -> UInt32 {
            UInt32(data[position]) << 24 | UInt32(data[position + 1]) << 16 |
                UInt32(data[position + 2]) << 8 | UInt32(data[position + 3])
        }

        func uint64(at position: Int) -> UInt64 {
            UInt64(uint32(at: position)) << 32 | UInt64(uint32(at: position + 4))
        }
    }

    private struct FourCC: RawRepresentable, Hashable, Sendable {
        let rawValue: UInt32
        static let ftyp = Self(rawValue: 0x66747970)
        static let moov = Self(rawValue: 0x6d6f6f76)
        static let mdat = Self(rawValue: 0x6d646174)
        static let free = Self(rawValue: 0x66726565)
        static let trak = Self(rawValue: 0x7472616b)
        static let mdia = Self(rawValue: 0x6d646961)
        static let hdlr = Self(rawValue: 0x68646c72)
        static let soun = Self(rawValue: 0x736f756e)
        static let mdir = Self(rawValue: 0x6d646972)
        static let minf = Self(rawValue: 0x6d696e66)
        static let dinf = Self(rawValue: 0x64696e66)
        static let dref = Self(rawValue: 0x64726566)
        static let url = Self(rawValue: 0x75726c20)
        static let stbl = Self(rawValue: 0x7374626c)
        static let stsd = Self(rawValue: 0x73747364)
        static let stco = Self(rawValue: 0x7374636f)
        static let co64 = Self(rawValue: 0x636f3634)
        static let stts = Self(rawValue: 0x73747473)
        static let stsc = Self(rawValue: 0x73747363)
        static let stsz = Self(rawValue: 0x7374737a)
        static let stz2 = Self(rawValue: 0x73747a32)
        static let mp4a = Self(rawValue: 0x6d703461)
        static let alac = Self(rawValue: 0x616c6163)
        static let wave = Self(rawValue: 0x77617665)
        static let udta = Self(rawValue: 0x75647461)
        static let meta = Self(rawValue: 0x6d657461)
        static let ilst = Self(rawValue: 0x696c7374)
        static let data = Self(rawValue: 0x64617461)
        static let nam = Self(rawValue: 0xa96e616d)
        static let art = Self(rawValue: 0xa9415254)
        static let alb = Self(rawValue: 0xa9616c62)
        static let aart = Self(rawValue: 0x61415254)
        static let trkn = Self(rawValue: 0x74726b6e)
        static let disk = Self(rawValue: 0x6469736b)
        static let day = Self(rawValue: 0xa9646179)
        static let gen = Self(rawValue: 0xa967656e)
        static let gnre = Self(rawValue: 0x676e7265)
        static let wrt = Self(rawValue: 0xa9777274)
        static let cmt = Self(rawValue: 0xa9636d74)
        static let lyr = Self(rawValue: 0xa96c7972)
        static let covr = Self(rawValue: 0x636f7672)
        static let moof = Self(rawValue: 0x6d6f6f66)
        static let mfra = Self(rawValue: 0x6d667261)
        static let sidx = Self(rawValue: 0x73696478)
        static let ssix = Self(rawValue: 0x73736978)
        static let mvex = Self(rawValue: 0x6d766578)
        static let cmov = Self(rawValue: 0x636d6f76)
        static let sinf = Self(rawValue: 0x73696e66)
        static let schi = Self(rawValue: 0x73636869)
        static let senc = Self(rawValue: 0x73656e63)
        static let saio = Self(rawValue: 0x7361696f)
        static let saiz = Self(rawValue: 0x7361697a)
        static let tref = Self(rawValue: 0x74726566)
        static let keys = Self(rawValue: 0x6b657973)
        static let iloc = Self(rawValue: 0x696c6f63)
        static let iinf = Self(rawValue: 0x69696e66)
    }

    // The numeric gnre atom uses the standardized one-based ID3v1 genre index.
    private static let genreNames = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock",
        "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack",
        "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical",
        "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock",
        "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance",
        "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk",
        "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical",
        "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion",
        "Bebop", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock",
        "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus",
        "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music",
        "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
        "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet",
        "Punk Rock", "Drum Solo", "A cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass",
        "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Negerpunk", "Polsk Punk", "Beat",
        "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian",
        "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop"
    ]
}

enum M4AContainerError: LocalizedError, Equatable {
    case malformed(String)
    case unsupported(String)
    case invalidValue(String)
    case invalidArtwork

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): "This M4A file is invalid. It was left unchanged. \(reason)"
        case .unsupported(let reason): "This M4A file cannot be edited safely. \(reason)"
        case .invalidValue(let reason): reason
        case .invalidArtwork: "Artwork must be a JPEG or PNG image no larger than 32 MB."
        }
    }
}
