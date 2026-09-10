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
                        description: Text("Choose another audio file or try opening this file again.")
                    )
                }
            } else {
                ContentUnavailableView(
                    "Select an Audio File",
                    systemImage: "tag",
                    description: Text("Select an MP3 or M4A file to view and edit its tags.")
                )
            }
        }
        .navigationTitle("Tags")
    }

    private func editor(for fileURL: URL) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.filenameDraft?.proposedFilename ?? fileURL.lastPathComponent)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    Text(fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    session.startAutoTagSearch()
                } label: {
                    Label("Find Tags…", systemImage: "wand.and.stars")
                }
                .disabled(!session.canFindTags)
                .help("Find tag suggestions from the file name and MusicBrainz")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            Form {
                Section("File") {
                    LabeledContent("File Name") {
                        HStack(spacing: 4) {
                            TextField("File Name", text: filenameStemBinding)
                                .labelsHidden()
                                .accessibilityLabel("File name")
                                .accessibilityHint(
                                    "The \(session.filenameDraft?.extensionSuffix ?? ".\(fileURL.pathExtension)") extension is preserved."
                                )
                                .help("Edit the file name. The original extension is preserved.")

                            Text(session.filenameDraft?.extensionSuffix ?? ".\(fileURL.pathExtension)")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }

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
            // Keep the scrollable form's intrinsic height out of the window minimum.
            .frame(minHeight: 0, maxHeight: .infinity)
            .disabled(session.isSaving)

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

    private var filenameStemBinding: Binding<String> {
        Binding(
            get: { session.filenameDraft?.stem ?? "" },
            set: { newValue in
                session.filenameDraft?.stem = newValue
                session.statusMessage = nil
            }
        )
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
