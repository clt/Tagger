import SwiftUI

struct TagEditorView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Group {
            if session.selectedFileURLs.count > 1 {
                BatchTagEditorView(session: session)
            } else if let fileURL = session.selectedFileURL {
                if session.isLoadingTag {
                    ProgressView("Reading tags…")
                } else if session.draft != nil {
                    editor(for: fileURL)
                } else {
                    ContentUnavailableView(
                        "Tags Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Choose another MP3 or try opening this file again.")
                    )
                }
            } else {
                ContentUnavailableView(
                    "Select an MP3",
                    systemImage: "tag",
                    description: Text("Select a file to view and edit its ID3 tags.")
                )
            }
        }
        .navigationTitle("Tags")
    }

    private func editor(for fileURL: URL) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fileURL.deletingPathExtension().lastPathComponent)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)

                Text(fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            Form {
                Section("Basic") {
                    TextField("Title", text: textBinding(\.title))
                    TextField("Artist", text: textBinding(\.artist))
                    TextField("Album", text: textBinding(\.album))
                    TextField("Album Artist", text: textBinding(\.albumArtist))
                    TextField("Genre", text: textBinding(\.genre))
                    TextField("Composer", text: textBinding(\.composer))
                }

                Section("Position") {
                    TextField("Track Number", text: textBinding(\.trackNumber))
                    TextField("Disc Number", text: textBinding(\.discNumber))
                    TextField("Year", text: textBinding(\.year))
                }

                Section("Artwork") {
                    ArtworkEditorView(session: session)
                }

                Section("Comment") {
                    TextEditor(text: textBinding(\.comment))
                        .font(.body)
                        .frame(minHeight: 80)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.separator, lineWidth: 1)
                        }
                }

                Section("Lyrics") {
                    TextEditor(text: textBinding(\.lyrics))
                        .font(.body)
                        .frame(minHeight: 180)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.separator, lineWidth: 1)
                        }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                if let validationMessage = session.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let statusMessage = session.statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if session.isDirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Revert") {
                    session.revert()
                }
                .disabled(!session.canRevert)

                Button("Save") {
                    Task { await session.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canSave)
            }
            .padding()
        }
    }

    private func textBinding(_ keyPath: WritableKeyPath<ID3TagDraft, String>) -> Binding<String> {
        Binding(
            get: { session.draft?[keyPath: keyPath] ?? "" },
            set: { newValue in
                session.draft?[keyPath: keyPath] = newValue
                session.statusMessage = nil
            }
        )
    }
}
