import Foundation
import XCTest
@testable import Tagger

final class BatchID3TagDraftTests: XCTestCase {
    func testAggregatesSharedAndMixedTextValues() {
        let shared = BatchTextFieldDraft(values: ["Shared", "Shared"])
        XCTAssertEqual(shared.source, .shared("Shared"))
        XCTAssertEqual(shared.text, "Shared")
        XCTAssertEqual(shared.placeholder, "")
        XCTAssertFalse(shared.isApplied)

        let mixed = BatchTextFieldDraft(values: ["First", "Second"])
        XCTAssertEqual(mixed.source, .mixed)
        XCTAssertEqual(mixed.text, "")
        XCTAssertEqual(mixed.placeholder, "Mixed Values")
        XCTAssertFalse(mixed.isApplied)
    }

    func testApplyingOneFieldPreservesEveryUntouchedField() {
        let original = ID3TagDraft(
            title: "Original Title",
            artist: "Original Artist",
            album: "Original Album",
            albumArtist: "Original Album Artist",
            trackNumber: "4",
            discNumber: "2",
            year: "1999",
            genre: "Original Genre",
            composer: "Original Composer",
            comment: "Original Comment",
            lyrics: "Original Lyrics",
            artworkData: Data([0x01, 0x02])
        )
        var batch = BatchID3TagDraft(drafts: [original, ID3TagDraft()])

        batch.artist.text = "Updated Artist"
        let updated = batch.applying(to: original)

        var expected = original
        expected.artist = "Updated Artist"
        XCTAssertEqual(updated, expected)
        XCTAssertTrue(batch.isDirty)
    }

    func testCheckingAnEmptyMixedFieldExplicitlyClearsIt() {
        var field = BatchTextFieldDraft(values: ["First", "Second"])

        field.isApplied = true

        XCTAssertEqual(field.edit, .clear)
        XCTAssertEqual(field.applying(to: "Keep unless explicitly cleared"), "")
        XCTAssertTrue(field.isApplied)

        field.isApplied = false
        XCTAssertEqual(field.edit, .unchanged)
        XCTAssertEqual(field.applying(to: "Preserved"), "Preserved")
    }

    func testArtworkCanRemainUnchangedBeReplacedOrBeRemoved() {
        let first = Data([0x01])
        let second = Data([0x02])
        let replacement = Data([0x03, 0x04])
        var artwork = BatchArtworkFieldDraft(values: [first, second])

        XCTAssertEqual(artwork.source, .mixed)
        XCTAssertEqual(artwork.edit, .unchanged)
        XCTAssertEqual(artwork.applying(to: first), first)
        XCTAssertEqual(artwork.applying(to: second), second)

        artwork.replace(with: replacement)
        XCTAssertEqual(artwork.edit, .replace(replacement))
        XCTAssertEqual(artwork.applying(to: first), replacement)

        artwork.remove()
        XCTAssertEqual(artwork.edit, .remove)
        XCTAssertNil(artwork.applying(to: first))

        artwork.isApplied = false
        XCTAssertEqual(artwork.edit, .unchanged)
        XCTAssertEqual(artwork.applying(to: first), first)
    }

    func testOnlyAppliedNumericFieldsAreValidated() {
        var source = ID3TagDraft()
        source.trackNumber = "side A"
        source.discNumber = "disc one"
        source.year = "20260"
        var batch = BatchID3TagDraft(drafts: [source])

        XCTAssertNil(batch.validationMessage)

        batch.trackNumber.isApplied = true
        XCTAssertEqual(
            batch.validationMessage,
            "Track number must be a whole number greater than zero."
        )

        batch.trackNumber.isApplied = false
        batch.discNumber.isApplied = true
        XCTAssertEqual(
            batch.validationMessage,
            "Disc number must be a whole number greater than zero."
        )

        batch.discNumber.isApplied = false
        batch.year.isApplied = true
        XCTAssertEqual(batch.validationMessage, "Year must contain no more than four digits.")

        batch.year.text = ""
        XCTAssertEqual(batch.year.edit, .clear)
        XCTAssertNil(batch.validationMessage)
    }

    func testRebaseRefreshesAggregateValuesAndKeepsPendingEdits() {
        var first = ID3TagDraft()
        first.title = "Before"
        let second = first

        var batch = BatchID3TagDraft(drafts: [first, second])
        batch.title.text = "After"

        first.title = "After"
        let rebased = batch.rebased(on: [first, second])

        XCTAssertEqual(rebased.title.source, .mixed)
        XCTAssertEqual(rebased.title.edit, .set("After"))
        XCTAssertTrue(rebased.isDirty)

        var unapplied = rebased
        unapplied.title.isApplied = false
        XCTAssertEqual(unapplied.title.source, .mixed)
        XCTAssertEqual(unapplied.title.edit, .unchanged)
    }
}
