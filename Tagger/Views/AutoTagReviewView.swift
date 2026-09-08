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
                Text("Find Tags")
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
            progressView("Loading release details…")
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
                Text("Searching sends the title, artist, and album above to MusicBrainz. Your audio and full file path stay on this Mac.")
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
                .accessibilityHint("Review this candidate before applying any fields")
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

                if rows.isEmpty {
                    ContentUnavailableView(
                        "Tags Already Match",
                        systemImage: "checkmark.circle",
                        description: Text("This candidate does not change any supported fields.")
                    )
                } else {
                    List(rows) { row in
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

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing is written until you click Save.")
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
