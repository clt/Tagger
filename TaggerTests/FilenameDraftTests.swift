import Foundation
import XCTest
@testable import Tagger

final class FilenameDraftTests: XCTestCase {
    func testEditingStemPreservesOriginalExtensionAndTracksDirtyState() {
        let url = URL(fileURLWithPath: "/Music/Original.MP3")
        var draft = FilenameDraft(url: url)

        XCTAssertEqual(draft.originalStem, "Original")
        XCTAssertEqual(draft.pathExtension, "MP3")
        XCTAssertEqual(draft.extensionSuffix, ".MP3")
        XCTAssertEqual(draft.originalFilename, "Original.MP3")
        XCTAssertEqual(draft.proposedFilename, "Original.MP3")
        XCTAssertFalse(draft.isDirty)

        draft.stem = "Renamed.Track"

        XCTAssertEqual(draft.proposedFilename, "Renamed.Track.MP3")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNil(draft.validationMessage)
    }

    func testRevertRestoresOriginalStem() {
        var draft = FilenameDraft(
            url: URL(fileURLWithPath: "/Music/Original.mp3")
        )
        draft.stem = "Changed"

        draft.revert()

        XCTAssertEqual(draft.stem, "Original")
        XCTAssertEqual(draft.proposedFilename, "Original.mp3")
        XCTAssertFalse(draft.isDirty)
    }

    func testValidationRejectsUnsafeOrInvisibleStems() {
        let invalidCases: [(stem: String, message: String)] = [
            ("   \n", "File name can’t be empty."),
            (".", "File name can’t be “.” or “..”."),
            ("..", "File name can’t be “.” or “..”."),
            (".hidden", "File name can’t begin with a period because hidden files aren’t shown."),
            ("folder/song", "File name can’t contain “/” or “:”."),
            ("artist:song", "File name can’t contain “/” or “:”."),
            ("line\nbreak", "File name can’t contain line breaks or control characters."),
            ("line\u{2028}break", "File name can’t contain line breaks or control characters."),
            ("paragraph\u{2029}break", "File name can’t contain line breaks or control characters."),
        ]

        for testCase in invalidCases {
            XCTAssertEqual(
                FilenameDraft.validationMessage(for: testCase.stem),
                testCase.message,
                "Expected \(testCase.stem.debugDescription) to be rejected"
            )
        }

        XCTAssertNil(FilenameDraft.validationMessage(for: "A valid song name"))
    }
}
