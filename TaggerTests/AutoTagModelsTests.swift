import Foundation
import XCTest
@testable import Tagger

final class AutoTagModelsTests: XCTestCase {
    func testReviewDefaultsToEmptyFieldsAndRequiresOptInForReplacement() {
        let current = ID3TagDraft(
            title: "Existing Title",
            artist: "",
            album: "Existing Album",
            comment: "Keep this",
            artworkData: Data([0x01, 0x02])
        )
        let proposal = proposal(
            values: AutoTagValues(
                title: "Suggested Title",
                artist: "Suggested Artist",
                album: "Suggested Album",
                albumArtist: nil,
                trackNumber: "4",
                discNumber: nil,
                year: nil
            )
        )

        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: current)

        XCTAssertEqual(review.selectedFields, [.artist, .trackNumber])
        var applied = review.applying(to: current)
        XCTAssertEqual(applied.title, "Existing Title")
        XCTAssertEqual(applied.artist, "Suggested Artist")
        XCTAssertEqual(applied.album, "Existing Album")
        XCTAssertEqual(applied.trackNumber, "4")
        XCTAssertEqual(applied.comment, "Keep this")
        XCTAssertEqual(applied.artworkData, Data([0x01, 0x02]))

        review.selectedFields.insert(.title)
        applied = review.applying(to: current)
        XCTAssertEqual(applied.title, "Suggested Title")
    }

    func testMissingSuggestionNeverClearsAField() {
        let current = ID3TagDraft(
            title: "Keep Title",
            artist: "Keep Artist",
            genre: "Keep Genre",
            lyrics: "Keep Lyrics"
        )
        let proposal = proposal(
            values: AutoTagValues(
                title: nil,
                artist: nil,
                album: "New Album",
                albumArtist: nil,
                trackNumber: nil,
                discNumber: nil,
                year: nil
            )
        )
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: current)
        review.selectedFields.formUnion([.title, .artist, .album])

        let applied = review.applying(to: current)

        XCTAssertEqual(applied.title, "Keep Title")
        XCTAssertEqual(applied.artist, "Keep Artist")
        XCTAssertEqual(applied.album, "New Album")
        XCTAssertEqual(applied.genre, "Keep Genre")
        XCTAssertEqual(applied.lyrics, "Keep Lyrics")
    }

    func testBlankSuggestionsCannotEraseValuesAndAppliedValuesMatchReview() {
        let current = ID3TagDraft(title: "Keep Title", artist: "Keep Artist")
        var review = AutoTagReviewDraft(
            proposal: proposal(values: AutoTagValues(title: " \n ", artist: "", album: "  Dummy  ")),
            currentDraft: current
        )
        review.selectedFields.formUnion([.title, .artist, .album])

        XCTAssertEqual(review.rows(comparedTo: current).map(\.suggestedValue), ["Dummy"])
        let applied = review.applying(to: current)
        XCTAssertEqual(applied.title, "Keep Title")
        XCTAssertEqual(applied.artist, "Keep Artist")
        XCTAssertEqual(applied.album, "Dummy")
    }

    func testArtworkOnlySuggestionIsSelectedForAnEmptyDraft() {
        let current = ID3TagDraft()
        let proposal = proposal(values: AutoTagValues(), artwork: Data([1, 2, 3]))
        let review = AutoTagReviewDraft(proposal: proposal, currentDraft: current)

        XCTAssertTrue(review.rows(comparedTo: current).isEmpty)
        XCTAssertTrue(review.isArtworkSelected)
        XCTAssertTrue(review.hasArtworkChange(comparedTo: current))
        XCTAssertTrue(review.hasSelectedChanges(comparedTo: current))
        XCTAssertEqual(review.applying(to: current).artworkData, Data([1, 2, 3]))
        XCTAssertNil(current.artworkData)
    }

    func testArtworkReplacementRequiresOptInAndPreservesOtherFields() {
        let current = ID3TagDraft(
            title: "Keep title",
            genre: "Keep genre",
            composer: "Keep composer",
            comment: "Keep comment",
            lyrics: "Keep lyrics",
            artworkData: Data([1])
        )
        let proposal = proposal(values: AutoTagValues(), artwork: Data([2]))
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: current)

        XCTAssertFalse(review.isArtworkSelected)
        XCTAssertTrue(review.hasArtworkChange(comparedTo: current))
        XCTAssertFalse(review.hasSelectedChanges(comparedTo: current))
        XCTAssertEqual(review.applying(to: current), current)

        review.isArtworkSelected = true
        var expected = current
        expected.artworkData = Data([2])
        XCTAssertEqual(review.applying(to: current), expected)
        XCTAssertTrue(review.hasSelectedChanges(comparedTo: current))
    }

    func testUncheckingArtworkKeepsTextChangesAndLeavesArtworkUntouched() {
        let current = ID3TagDraft()
        let proposal = proposal(values: AutoTagValues(title: "New title"), artwork: Data([2]))
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: current)
        XCTAssertTrue(review.isArtworkSelected)

        review.isArtworkSelected = false

        XCTAssertEqual(review.applying(to: current), ID3TagDraft(title: "New title"))
        XCTAssertTrue(review.hasSelectedChanges(comparedTo: current))
    }

    func testMissingArtworkNeverRemovesAnExistingImage() {
        let current = ID3TagDraft(artworkData: Data([1]))
        var review = AutoTagReviewDraft(
            proposal: proposal(values: AutoTagValues()),
            currentDraft: current
        )
        XCTAssertFalse(review.isArtworkSelected)
        XCTAssertFalse(review.hasArtworkChange(comparedTo: current))
        review.isArtworkSelected = true

        XCTAssertEqual(review.applying(to: current), current)
        XCTAssertFalse(review.hasSelectedChanges(comparedTo: current))
    }

    func testIdenticalArtworkDoesNotCreateAChange() {
        let current = ID3TagDraft(artworkData: Data([1]))
        var review = AutoTagReviewDraft(
            proposal: proposal(values: AutoTagValues(), artwork: Data([1])),
            currentDraft: current
        )

        XCTAssertFalse(review.isArtworkSelected)
        XCTAssertFalse(review.hasArtworkChange(comparedTo: current))
        review.isArtworkSelected = true
        XCTAssertFalse(review.hasSelectedChanges(comparedTo: current))
        XCTAssertEqual(review.applying(to: current), current)
    }

    func testArtworkAlternativesUseStableIdentityAndKeepThePrimaryChoice() {
        let primary = cover("archive", data: 1)
        let apple = cover("apple", data: 2, provider: .appleCatalog)
        var proposal = proposal(values: AutoTagValues())
        proposal.artwork = primary
        proposal.artworkAlternatives = [primary, apple, apple]
        let review = AutoTagReviewDraft(proposal: proposal, currentDraft: ID3TagDraft())

        XCTAssertEqual(primary.id, primary.sourceURL.absoluteString)
        XCTAssertEqual(review.availableArtwork.map(\.id), [primary.id, apple.id])
        XCTAssertEqual(review.selectedArtwork, primary)
        XCTAssertEqual(review.applying(to: ID3TagDraft()).artworkData, primary.data)
    }

    func testChoosingAlternativeAppliesThatImageAndPreservesTextSelection() {
        let primary = cover("archive", data: 1)
        let apple = cover("apple", data: 2, provider: .appleCatalog)
        var proposal = proposal(values: AutoTagValues(title: "Suggested title", album: "Suggested album"))
        proposal.artwork = primary
        proposal.artworkAlternatives = [apple]
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: ID3TagDraft())
        review.selectedFields.remove(.album)
        let selectedFields = review.selectedFields
        review.selectedArtworkID = apple.id

        XCTAssertEqual(review.selectedArtwork, apple)
        XCTAssertEqual(review.selectedFields, selectedFields)
        XCTAssertEqual(review.applying(to: ID3TagDraft()), ID3TagDraft(title: "Suggested title", artworkData: apple.data))
    }

    func testAppendingCoversPreservesUserSelectionAndUncheckedIntent() {
        let primary = cover("archive", data: 1)
        let apple = cover("apple", data: 2, provider: .appleCatalog)
        var proposal = proposal(values: AutoTagValues())
        proposal.artwork = primary
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: ID3TagDraft())
        review.isArtworkSelected = false
        review.proposal.artworkAlternatives.append(apple)

        XCTAssertEqual(review.selectedArtworkID, primary.id)
        XCTAssertFalse(review.isArtworkSelected)
        review.selectedArtworkID = apple.id
        XCTAssertFalse(review.isArtworkSelected)
        XCTAssertNil(review.applying(to: ID3TagDraft()).artworkData)
    }

    func testAlternativesWithoutPrimaryRequireAnExplicitCoverChoice() {
        let apple = cover("apple", data: 2, provider: .appleCatalog)
        var review = AutoTagReviewDraft(proposal: proposal(values: AutoTagValues()), currentDraft: ID3TagDraft())
        review.proposal.artworkAlternatives.append(apple)

        XCTAssertNil(review.selectedArtworkID)
        XCTAssertNil(review.selectedArtwork)
        XCTAssertFalse(review.isArtworkSelected)
        XCTAssertFalse(review.hasArtworkChange(comparedTo: ID3TagDraft()))
        review.selectedArtworkID = apple.id
        XCTAssertTrue(review.hasArtworkChange(comparedTo: ID3TagDraft()))
        review.isArtworkSelected = true
        XCTAssertEqual(review.applying(to: ID3TagDraft()).artworkData, apple.data)
    }

    func testMissingSelectedIdentityDoesNotFallBackToAnotherCover() {
        let primary = cover("archive", data: 1)
        var proposal = proposal(values: AutoTagValues())
        proposal.artwork = primary
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: ID3TagDraft())
        review.selectedArtworkID = "missing-cover"

        XCTAssertNil(review.selectedArtwork)
        XCTAssertFalse(review.hasArtworkChange(comparedTo: ID3TagDraft()))
        XCTAssertNil(review.applying(to: ID3TagDraft()).artworkData)
    }

    func testChoosingAnotherCoverNeverOptsInToReplacingExistingArtwork() {
        let primary = cover("archive", data: 1)
        let apple = cover("apple", data: 2, provider: .appleCatalog)
        let current = ID3TagDraft(artworkData: primary.data)
        var proposal = proposal(values: AutoTagValues())
        proposal.artwork = primary
        proposal.artworkAlternatives = [apple]
        var review = AutoTagReviewDraft(proposal: proposal, currentDraft: current)
        XCTAssertFalse(review.hasArtworkChange(comparedTo: current))
        review.selectedArtworkID = apple.id

        XCTAssertTrue(review.hasArtworkChange(comparedTo: current))
        XCTAssertFalse(review.isArtworkSelected)
        XCTAssertEqual(review.applying(to: current), current)
        review.isArtworkSelected = true
        XCTAssertEqual(review.applying(to: current).artworkData, apple.data)
    }

    private func cover(_ identifier: String, data: UInt8, provider: AutoTagArtworkSource = .coverArtArchive) -> AutoTagArtwork {
        AutoTagArtwork(
            data: Data([data]),
            sourceURL: URL(string: "https://example.com/\(identifier)")!,
            provider: provider,
            pixelWidth: 600,
            pixelHeight: 600,
            title: "Album",
            subtitle: "Artist · 2026"
        )
    }

    private func proposal(values: AutoTagValues, artwork: Data? = nil) -> AutoTagProposal {
        let candidate = AutoTagCandidate(
            id: "test",
            source: .musicBrainz,
            title: values.title ?? "Test",
            subtitle: "Test Artist",
            matchScore: 100,
            reference: .musicBrainz(recordingID: "recording", releaseID: "release"),
            preview: values
        )
        return AutoTagProposal(
            candidate: candidate,
            values: values,
            artwork: artwork.map {
                AutoTagArtwork(data: $0, sourceURL: URL(string: "https://coverartarchive.org/release/test")!)
            }
        )
    }
}
