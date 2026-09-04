import Foundation
import XCTest
@testable import Tagger

final class FilenameTagInferenceTests: XCTestCase {
    private let inference = FilenameTagInference()

    func testInfersTrackArtistAndTitleFromCommonFileName() {
        let values = inference.values(
            for: URL(fileURLWithPath: "/Music/Dummy/01 - Portishead - Roads.mp3")
        )

        XCTAssertEqual(values.trackNumber, "1")
        XCTAssertNil(values.discNumber)
        XCTAssertEqual(values.artist, "Portishead")
        XCTAssertEqual(values.title, "Roads")
    }

    func testInfersDiscTrackAndNormalizesUnderscores() {
        let values = inference.values(
            for: URL(fileURLWithPath: "/Music/1-03 - Artist - Song_Name.mp3")
        )

        XCTAssertEqual(values.discNumber, "1")
        XCTAssertEqual(values.trackNumber, "3")
        XCTAssertEqual(values.artist, "Artist")
        XCTAssertEqual(values.title, "Song Name")
    }

    func testPreservesOrdinaryHyphensAndAvoidsAmbiguousArtistSplit() {
        let hyphenated = inference.values(
            for: URL(fileURLWithPath: "/Music/Spider-Man Theme.mp3")
        )
        let ambiguous = inference.values(
            for: URL(fileURLWithPath: "/Music/Artist - Remix - Title.mp3")
        )

        XCTAssertNil(hyphenated.artist)
        XCTAssertEqual(hyphenated.title, "Spider-Man Theme")
        XCTAssertNil(ambiguous.artist)
        XCTAssertEqual(ambiguous.title, "Artist - Remix - Title")
    }

    func testSearchSeedPrefersCurrentDraftOverFileName() {
        let request = AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/Music/File Artist - File Title.mp3"),
            currentDraft: ID3TagDraft(
                title: "Edited Title",
                artist: "Edited Artist",
                album: "Edited Album"
            )
        )

        XCTAssertEqual(
            inference.searchSeed(for: request),
            MusicBrainzSearchSeed(
                title: "Edited Title",
                artist: "Edited Artist",
                album: "Edited Album"
            )
        )
    }

    func testMatchingFileNameDoesNotProduceRedundantCandidate() {
        let request = AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/Music/01 - Artist - Title.mp3"),
            currentDraft: ID3TagDraft(
                title: "Title",
                artist: "Artist",
                trackNumber: "1"
            )
        )

        XCTAssertNil(inference.candidate(for: request))
    }
}
