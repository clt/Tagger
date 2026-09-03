import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkEditorView: View {
    @Bindable var session: LibrarySession
    @State private var isShowingArtworkImporter = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            artworkPreview
                .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                Button("Choose Artwork…") {
                    isShowingArtworkImporter = true
                }

                Button("Remove Artwork", role: .destructive) {
                    session.removeArtwork()
                }
                .disabled(session.draft?.artworkData == nil)

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
        if let data = session.draft?.artworkData,
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
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
        }
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
                    throw ArtworkImportError.invalidImage
                }
                session.replaceArtwork(with: data)
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

private enum ArtworkImportError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected file is not a valid JPEG or PNG image."
    }
}
