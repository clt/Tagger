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

    func testInfersZeroPaddedTrackWithWhitespaceForM4AAndMP3() {
        let examples = [
            ("01 Safe From Harm.m4a", "1", "Safe From Harm", nil as String?),
            ("09 Hymn of the Big Wheel.m4a", "9", "Hymn of the Big Wheel", nil),
            ("001 Roads.mp3", "1", "Roads", nil),
            ("03 Portishead - Glory Box.mp3", "3", "Glory Box", "Portishead"),
        ]
        for (name, track, title, artist) in examples {
            let values = inference.values(for: URL(fileURLWithPath: "/Music/" + name))
            XCTAssertEqual(values.trackNumber, track, name)
            XCTAssertEqual(values.title, title, name)
            XCTAssertEqual(values.artist, artist, name)
            XCTAssertNil(values.discNumber, name)
        }
    }

    func testDoesNotTreatOrdinaryNumericTitlesAsWhitespaceTrackPrefixes() {
        for stem in ["99 Luftballons", "1979", "4 Minutes", "01", "001", "00 Intro", "01 1979"] {
            for fileExtension in ["m4a", "mp3"] {
                let values = inference.values(for: URL(fileURLWithPath: "/Music/\(stem).\(fileExtension)"))
                XCTAssertEqual(values.title, stem)
                XCTAssertNil(values.trackNumber, stem)
                XCTAssertNil(values.discNumber, stem)
            }
        }
    }

    func testM4ASearchSeedOmitsZeroPaddedTrackPrefix() {
        let request = AutoTagSearchRequest(
            fileURL: URL(fileURLWithPath: "/Music/01 Safe From Harm.m4a"),
            currentDraft: ID3TagDraft()
        )

        XCTAssertEqual(
            inference.searchSeed(for: request),
            MusicBrainzSearchSeed(title: "Safe From Harm", artist: nil, album: nil)
        )
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
