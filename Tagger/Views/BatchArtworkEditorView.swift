import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BatchArtworkEditorView: View {
    @Bindable var session: LibrarySession
    @State private var isShowingArtworkImporter = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            artworkPreview
                .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                Text(artworkStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Replace for All…") {
                    isShowingArtworkImporter = true
                }
                .disabled(session.isSaving || session.batchDraft == nil)
                .accessibilityHint("Choose JPEG or PNG artwork for every selected file")

                Button("Remove from All", role: .destructive) {
                    session.batchDraft?.artworkData.remove()
                    session.statusMessage = nil
                }
                .disabled(session.isSaving || session.batchDraft == nil)
                .accessibilityHint("Removes artwork from every selected file when saved")

                Button("Keep Existing") {
                    session.batchDraft?.artworkData.edit = .unchanged
                    session.statusMessage = nil
                }
                .disabled(session.isSaving || artworkField?.isApplied != true)
                .accessibilityHint("Leaves each selected file’s artwork unchanged")

                Text("JPEG or PNG")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(
            isPresented: $isShowingArtworkImporter,
            allowedContentTypes: [.jpeg, .png]
        ) { result in
            importArtwork(result)
        }
    }

    @ViewBuilder
    private var artworkPreview: some View {
        if let data = artworkField?.data,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityLabel(artworkPreviewAccessibilityLabel)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: isMixedArtwork ? "photo.stack" : "photo")
                            .font(.system(size: 34))

                        Text(isMixedArtwork ? "Multiple\nArtworks" : "No Artwork")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(artworkPreviewAccessibilityLabel)
        }
    }

    private var artworkField: BatchArtworkFieldDraft? {
        session.batchDraft?.artworkData
    }

    private var isMixedArtwork: Bool {
        guard let artworkField,
              artworkField.edit == .unchanged,
              artworkField.source == .mixed else {
            return false
        }
        return true
    }

    private var artworkStatus: String {
        guard let artworkField else { return "Artwork unavailable" }

        switch artworkField.edit {
        case .replace:
            return "Replacement artwork will be applied to all \(fileCount) files."
        case .remove:
            return "Artwork will be removed from all \(fileCount) files."
        case .unchanged:
            switch artworkField.source {
            case .mixed:
                return "The selected files have multiple artworks."
            case .shared(let data):
                return data == nil
                    ? "The selected files have no artwork."
                    : "The selected files share this artwork."
            }
        }
    }

    private var artworkPreviewAccessibilityLabel: String {
        guard let artworkField else { return "Artwork unavailable" }

        switch artworkField.edit {
        case .replace:
            return "Replacement artwork for all selected files"
        case .remove:
            return "Artwork will be removed from all selected files"
        case .unchanged:
            switch artworkField.source {
            case .mixed:
                return "Multiple existing artworks"
            case .shared(let data):
                return data == nil ? "No existing artwork" : "Shared existing artwork"
            }
        }
    }

    private var fileCount: Int {
        session.selectedFileURLs.count
    }

    private func importArtwork(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                guard NSImage(data: data) != nil else {
                    throw BatchArtworkImportError.invalidImage
                }
                session.batchDraft?.artworkData.replace(with: data)
                session.statusMessage = nil
            } catch {
                session.present(error, title: "Couldn’t Load Artwork")
            }

        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                session.present(error, title: "Couldn’t Load Artwork")
            }
        }
    }
}

private enum BatchArtworkImportError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected file is not a valid JPEG or PNG image."
    }
}
