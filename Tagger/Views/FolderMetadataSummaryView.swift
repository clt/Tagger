import AppKit
import SwiftUI

/// A read-only overview of the current folder, including any unsaved edit draft.
struct FolderMetadataSummaryView: View {
    let summary: FolderMetadataSummary
    let isLoading: Bool
    let hasUnsavedChanges: Bool
    let artworkSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            artwork

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.albumText)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(summary.albumText)
                    .accessibilityLabel("Album: \(summary.albumText)")

                Text(summary.artistText)
                    .font(.body)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(summary.artistText)
                    .accessibilityLabel("Artist: \(summary.artistText)")

                Text("\(fileCountText) · Folder summary")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                if !statusText.isEmpty {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(statusText)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(statusText)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statusText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: artworkSize, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder metadata summary")
    }

    private var fileCountText: String {
        summary.fileCount == 1 ? "1 audio file" : "\(summary.fileCount) audio files"
    }

    private var statusText: String {
        var parts: [String] = []
        if isLoading { parts.append("Reading metadata…") }
        if hasUnsavedChanges { parts.append("Unsaved changes") }
        if summary.unreadableCount > 0 {
            parts.append(summary.unreadableCount == 1
                         ? "Metadata unavailable for 1 file"
                         : "Metadata unavailable for \(summary.unreadableCount) files")
        }
        return parts.joined(separator: " · ")
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)

            if let data = summary.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Album cover")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: min(44, artworkSize * 0.28), weight: .light))
                    Text(summary.artworkPlaceholder)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(8)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
