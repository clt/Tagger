import AppKit
import SwiftUI
import XCTest
@testable import Tagger

final class WindowFrameBoundsTests: XCTestCase {
    @MainActor
    func testBatchEditorMinimumHeightDoesNotGrowWithSelectionOrLyrics() {
        let session = LibrarySession()
        session.selectedFileURLs = (1...46).map {
            URL(fileURLWithPath: "/Synthetic/Track \($0).mp3")
        }
        session.batchDraft = BatchID3TagDraft(drafts: (1...46).map {
            ID3TagDraft(title: "Song \($0)", lyrics: String(repeating: "Lyrics\n", count: 500))
        })
        let controller = NSHostingController(rootView: BatchTagEditorView(session: session))
        // SwiftUI probes zero width when deriving window constraints. An unbounded
        // wrapping header previously reported a height greater than 1,500 points.
        XCTAssertLessThanOrEqual(controller.sizeThatFits(in: .zero).height, 420)
        XCTAssertLessThanOrEqual(controller.sizeThatFits(in: NSSize(width: 430, height: 420)).height, 420)
    }

    func testOversizedRestoredWindowFitsAboveDockAndBelowMenuBar() {
        let visible = NSRect(x: 0, y: 90, width: 1440, height: 785)
        let restored = NSRect(x: 10, y: -500, width: 1320, height: 1375)
        let result = WindowFrameBounds.constrain(restored, to: visible)
        XCTAssertEqual(result, NSRect(x: 10, y: 90, width: 1320, height: 785))
    }

    func testValidUserSizesArePreservedOnBothAxes() {
        let visible = NSRect(x: 0, y: 90, width: 1440, height: 785)
        for size in [NSSize(width: 900, height: 460), NSSize(width: 1240, height: 700)] {
            let frame = NSRect(origin: NSPoint(x: 30, y: 120), size: size)
            XCTAssertEqual(WindowFrameBounds.constrain(frame, to: visible), frame)
        }
    }

    func testExternalDisplayWithNegativeOriginAndSideDock() {
        let visible = NSRect(x: -1820, y: -300, width: 1820, height: 1050)
        let frame = NSRect(x: -1920, y: -400, width: 2000, height: 1200)
        XCTAssertEqual(WindowFrameBounds.constrain(frame, to: visible), visible)
    }
}
