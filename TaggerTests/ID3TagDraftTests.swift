import XCTest
@testable import Tagger

final class ID3TagDraftTests: XCTestCase {
    func testBlankNumbersAreValid() throws {
        let values = try ID3TagDraft().validatedNumbers()
        XCTAssertNil(values.track)
        XCTAssertNil(values.disc)
        XCTAssertNil(values.year)
    }

    func testRejectsInvalidTrackNumber() {
        var draft = ID3TagDraft()
        draft.trackNumber = "side A"

        XCTAssertEqual(
            draft.validationMessage,
            "Track number must be a whole number greater than zero."
        )
    }

    func testRejectsFiveDigitYear() {
        var draft = ID3TagDraft()
        draft.year = "20_260"

        XCTAssertNotNil(draft.validationMessage)

        draft.year = "20260"
        XCTAssertEqual(draft.validationMessage, "Year must contain no more than four digits.")
    }
}
