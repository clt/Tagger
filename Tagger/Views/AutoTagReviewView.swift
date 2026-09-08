import AppKit
import SwiftUI

struct AutoTagReviewView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 640)
        .interactiveDismissDisabled(session.isAutoTagging)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Find Tags and Artwork")
                    .font(.title2.weight(.semibold))
                Text(session.selectedFileURL?.lastPathComponent ?? "Selected Audio File")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch session.autoTagPhase {
        case .searching, .choosing, .noResults:
            searchAndCandidates
        case .resolving:
            progressView("Loading release details and artwork…")
        case .reviewing:
            reviewList
        case .idle:
            EmptyView()
        }
    }

    private var searchAndCandidates: some View {
        VStack(spacing: 0) {
            musicBrainzSearchForm
            Divider()

            if session.autoTagPhase == .searching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching MusicBrainz…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            candidateList
        }
    }

    private var musicBrainzSearchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MusicBrainz Search (Optional)")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Title")
                    TextField("Title", text: $session.autoTagSearchTitle)
                        .accessibilityLabel("MusicBrainz search title")
                }
                GridRow {
                    Text("Artist")
                    TextField("Artist", text: $session.autoTagSearchArtist)
                        .accessibilityLabel("MusicBrainz search artist")
                }
                GridRow {
                    Text("Album")
                    TextField("Album", text: $session.autoTagSearchAlbum)
                        .accessibilityLabel("MusicBrainz search album")
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(session.isAutoTagging)
            .onSubmit {
                if session.canSearchMusicBrainz {
                    session.searchMusicBrainzTags()
                }
            }

            HStack(alignment: .center, spacing: 16) {
                Text("Searching sends the title, artist, and album above to MusicBrainz. Choosing a MusicBrainz result also requests its artwork from Cover Art Archive and Internet Archive. Your audio and full file path stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button("Search MusicBrainz") {
                    session.searchMusicBrainzTags()
                }
                .disabled(!session.canSearchMusicBrainz || session.isAutoTagging)
                .help("Search online using the title, artist, and album above")
            }

            Text("File name suggestions stay offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func progressView(_ title: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private var candidateList: some View {
        VStack(spacing: 0) {
            if let message = session.autoTagMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
            }

            List(session.autoTagCandidates) { candidate in
                Button {
                    session.resolveAutoTagCandidate(candidate)
                } label: {
                    HStack(spacing: 12) {
                        Image(
                            systemName: candidate.source == .musicBrainz
                                ? "globe"
                                : "doc.text.magnifyingglass"
                        )
                        .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(candidate.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(candidate.source.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let score = candidate.matchScore {
                                Text("Match \(score)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityHint(candidate.source == .musicBrainz
                    ? "Load release details and artwork for review before applying to the draft"
                    : "Review this file name suggestion offline")
            }
            .overlay {
                if session.autoTagCandidates.isEmpty {
                    if session.autoTagPhase != .searching {
                        ContentUnavailableView(
                            "No Suggestions",
                            systemImage: "magnifyingglass",
                            description: Text("Edit the title, artist, or album above, then search MusicBrainz.")
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reviewList: some View {
        if let review = session.autoTagReview,
           let currentDraft = session.draft {
            let rows = review.rows(comparedTo: currentDraft)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(review.proposal.candidate.title)
                            .font(.headline)
                        Text(review.proposal.candidate.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(review.proposal.candidate.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                if let message = review.proposal.artworkMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                }

                List {
                    artworkReviewRow(review, currentData: currentDraft.artworkData)

                    if rows.isEmpty && !review.hasArtworkChange(comparedTo: currentDraft) {
                        Label("Tags already match. You can still choose another cover.", systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(rows) { row in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    session.autoTagReview?.selectedFields.contains(row.field) == true
                                },
                                set: { isSelected in
                                    session.setAutoTagField(row.field, isSelected: isSelected)
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.field.displayName)
                                    .font(.body.weight(.medium))
                                HStack(spacing: 8) {
                                    Text(displayValue(row.currentValue))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .help(displayValue(row.currentValue))
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(row.suggestedValue)
                                        .lineLimit(2)
                                        .help(row.suggestedValue)
                                }
                                .font(.callout)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("\(row.field.displayName). Current: \(displayValue(row.currentValue)). Suggested: \(row.suggestedValue)")
                        .padding(.vertical, 3)
                    }
                }
            }
        } else {
            ContentUnavailableView("Suggestion Unavailable", systemImage: "exclamationmark.triangle")
        }
    }

    private func artworkReviewRow(_ review: AutoTagReviewDraft, currentData: Data?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Artwork", isOn: Binding(
                    get: { session.autoTagReview?.isArtworkSelected == true },
                    set: { session.setAutoTagArtwork(isSelected: $0) }
                ))
                .toggleStyle(.checkbox)
                .font(.body.weight(.medium))
                .disabled(review.selectedArtwork == nil)
                .accessibilityLabel(currentData == nil ? "Add selected artwork to draft" : "Replace current artwork in draft")

                Spacer()
                Button("Find Apple Music Covers") {
                    session.searchAppleArtwork()
                }
                .disabled(!session.canSearchAppleArtwork || session.isSearchingArtwork)
                .help("Search the Apple Music US catalog using this album and artist")
            }

            Text("Find Apple Music Covers sends the album and artist to Apple’s US catalog. Cover Art Archive artwork is fetched when you choose a MusicBrainz result.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if session.isSearchingArtwork {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding Apple Music covers…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = session.autoTagArtworkMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !review.availableArtwork.isEmpty {
                Picker("Cover", selection: Binding<String?>(
                    get: { session.autoTagReview?.selectedArtworkID },
                    set: { id in
                        if let id { session.selectAutoTagArtwork(id) }
                    }
                )) {
                    if review.selectedArtwork == nil {
                        Text("Choose a cover…").tag(nil as String?)
                    }
                    ForEach(review.availableArtwork) { artwork in
                        Text(artworkOptionLabel(artwork)).tag(Optional(artwork.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Suggested cover source and edition")
            }

            if currentData != nil || review.selectedArtwork != nil {
                HStack(alignment: .top, spacing: 16) {
                    artworkPreview(currentData, label: "Current artwork")
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 50)
                        .accessibilityHidden(true)
                    artworkPreview(review.selectedArtwork?.data, label: "Selected artwork", artwork: review.selectedArtwork)
                    Spacer(minLength: 0)
                }
            }

            if let artwork = review.selectedArtwork {
                Link("Artwork from \(artwork.provider.displayName)", destination: artwork.sourceURL)
                    .font(.caption)
                if let subtitle = artwork.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if currentData != nil {
                    Text("Select Artwork to replace the image in your draft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(review.availableArtwork.isEmpty
                    ? "No cover selected. Search Apple Music for an alternative."
                    : "Choose a cover, then select Artwork to add it to your draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func artworkOptionLabel(_ artwork: AutoTagArtwork) -> String {
        [artwork.provider.displayName, artwork.title, artwork.subtitle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func artworkPreview(_ data: Data?, label: String, artwork: AutoTagArtwork? = nil) -> some View {
        VStack(spacing: 5) {
            Group {
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(label)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay {
                            Text(data == nil ? "Not set" : "Preview unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("\(label): \(data == nil ? "not set" : "preview unavailable")")
                }
            }
            .frame(width: 110, height: 110)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let size = artworkDimensions(data, artwork: artwork) {
                Text(size)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let artwork {
                Text(artwork.provider == .appleCatalog ? "Catalog image" : (artwork.isOriginal ? "Original image" : "Thumbnail"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func artworkDimensions(_ data: Data?, artwork: AutoTagArtwork?) -> String? {
        if let width = artwork?.pixelWidth, let height = artwork?.pixelHeight {
            return "\(width) × \(height) px"
        }
        guard let data, let image = NSBitmapImageRep(data: data) else { return nil }
        return "\(image.pixelsWide) × \(image.pixelsHigh) px"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Apply to Draft updates tags and artwork in the editor. Save writes them to the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    "Metadata provided by MusicBrainz",
                    destination: URL(string: "https://musicbrainz.org")!
                )
                .font(.caption)
            }

            Spacer()

            if session.autoTagPhase == .reviewing {
                Button("Back") {
                    session.returnToAutoTagCandidates()
                }
            }

            Button("Cancel", role: .cancel) {
                session.cancelAutoTagging()
            }
            .keyboardShortcut(.cancelAction)

            if session.autoTagPhase == .reviewing {
                Button("Apply to Draft") {
                    session.applyAutoTagReview()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canApplyAutoTagReview)
                .help("Update the editor draft. Nothing is written until you click Save.")
            }
        }
        .padding()
    }

    private func displayValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not set" : value
    }
}
