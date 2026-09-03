import SwiftUI

struct BatchTagEditorView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Group {
            if session.isLoadingTag {
                ProgressView("Reading tags…")
            } else if session.batchDraft != nil {
                editor
            } else {
                ContentUnavailableView(
                    "Tags Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Choose another group of MP3 files and try again.")
                )
            }
        }
        .navigationTitle("Tags")
    }

    private var editor: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section("Basic") {
                    BatchTextFieldRow(
                        label: "Title",
                        fileCount: fileCount,
                        field: fieldBinding(\.title)
                    )
                    BatchTextFieldRow(
                        label: "Artist",
                        fileCount: fileCount,
                        field: fieldBinding(\.artist)
                    )
                    BatchTextFieldRow(
                        label: "Album",
                        fileCount: fileCount,
                        field: fieldBinding(\.album)
                    )
                    BatchTextFieldRow(
                        label: "Album Artist",
                        fileCount: fileCount,
                        field: fieldBinding(\.albumArtist)
                    )
                    BatchTextFieldRow(
                        label: "Genre",
                        fileCount: fileCount,
                        field: fieldBinding(\.genre)
                    )
                    BatchTextFieldRow(
                        label: "Composer",
                        fileCount: fileCount,
                        field: fieldBinding(\.composer)
                    )
                }

                Section("Position") {
                    BatchTextFieldRow(
                        label: "Track Number",
                        fileCount: fileCount,
                        field: fieldBinding(\.trackNumber)
                    )
                    BatchTextFieldRow(
                        label: "Disc Number",
                        fileCount: fileCount,
                        field: fieldBinding(\.discNumber)
                    )
                    BatchTextFieldRow(
                        label: "Year",
                        fileCount: fileCount,
                        field: fieldBinding(\.year)
                    )
                }

                Section("Artwork") {
                    BatchArtworkEditorView(session: session)
                }

                Section("Comment") {
                    BatchMultilineField(
                        label: "Comment",
                        minimumHeight: 80,
                        fileCount: fileCount,
                        field: fieldBinding(\.comment)
                    )
                }

                Section("Lyrics") {
                    BatchMultilineField(
                        label: "Lyrics",
                        minimumHeight: 180,
                        fileCount: fileCount,
                        field: fieldBinding(\.lyrics)
                    )
                }
            }
            .formStyle(.grouped)
            .disabled(session.isSaving)

            Divider()

            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Batch Edit")
                .font(.title2.weight(.semibold))
                .accessibilityHeading(.h1)

            Text(selectionDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Only fields marked Apply will be changed in every selected file. An applied empty field will be removed from all of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerStatus

            Spacer()

            Button("Revert") {
                session.revert()
            }
            .disabled(!session.isDirty || session.isSaving)
            .accessibilityHint("Leaves every selected file unchanged")

            Button(saveButtonTitle) {
                Task { await session.save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.canSave)
            .accessibilityHint("Writes the applied fields to every selected MP3 file")
        }
        .padding()
    }

    @ViewBuilder
    private var footerStatus: some View {
        if session.isSaving {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(
                    value: Double(session.saveProgressCompleted),
                    total: Double(max(session.saveProgressTotal, 1))
                )

                Text(saveProgressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 260, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Saving tags")
            .accessibilityValue(
                "\(session.saveProgressCompleted) of \(session.saveProgressTotal) files"
            )
        } else if let validationMessage = session.validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let statusMessage = session.statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if session.isDirty {
            Text("Unsaved batch changes")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Mark a field Apply to edit the selection")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileCount: Int {
        session.selectedFileURLs.count
    }

    private var selectionDescription: String {
        "\(fileCount) \(fileCount == 1 ? "MP3 file" : "MP3 files") selected"
    }

    private var saveButtonTitle: String {
        "Save \(fileCount) \(fileCount == 1 ? "File" : "Files")"
    }

    private var saveProgressDescription: String {
        let count = "\(session.saveProgressCompleted) of \(session.saveProgressTotal)"
        if let filename = session.saveProgressFilename {
            return "Saving \(count): \(filename)"
        }
        return "Saving \(count)…"
    }

    private func fieldBinding(
        _ keyPath: WritableKeyPath<BatchID3TagDraft, BatchTextFieldDraft>
    ) -> Binding<BatchTextFieldDraft> {
        Binding(
            get: {
                session.batchDraft?[keyPath: keyPath]
                    ?? BatchTextFieldDraft(values: [])
            },
            set: { newValue in
                session.batchDraft?[keyPath: keyPath] = newValue
                session.statusMessage = nil
            }
        )
    }
}

private struct BatchTextFieldRow: View {
    let label: String
    let fileCount: Int
    @Binding var field: BatchTextFieldDraft

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                TextField(
                    label,
                    text: textBinding,
                    prompt: Text(prompt)
                )
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(textFieldHint)

                Toggle("Apply", isOn: applyBinding)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .accessibilityLabel("Apply \(label) to all \(fileCount) files")
                    .accessibilityHint(applyHint)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { field.text },
            set: { newValue in
                var updated = field
                updated.text = newValue
                field = updated
            }
        )
    }

    private var applyBinding: Binding<Bool> {
        Binding(
            get: { field.isApplied },
            set: { newValue in
                var updated = field
                updated.isApplied = newValue
                field = updated
            }
        )
    }

    private var prompt: String {
        if field.isApplied, field.text.isEmpty {
            return "Will Remove"
        }
        if !field.isApplied, field.source == .mixed {
            return "Multiple Values"
        }
        return ""
    }

    private var accessibilityValue: String {
        if !field.isApplied, field.source == .mixed {
            return "Multiple Values"
        }
        if field.text.isEmpty {
            return field.isApplied ? "Empty; will be removed" : "Empty"
        }
        return field.text
    }

    private var textFieldHint: String {
        if field.isApplied {
            return "This value will be applied to all \(fileCount) files"
        }
        return "Editing automatically marks this field Apply"
    }

    private var applyHint: String {
        if field.isApplied, field.text.isEmpty {
            return "This field will be removed from all selected files"
        }
        return field.isApplied
            ? "This field will be applied to all selected files"
            : "Each file will keep its existing value"
    }
}

private struct BatchMultilineField: View {
    let label: String
    let minimumHeight: CGFloat
    let fileCount: Int
    @Binding var field: BatchTextFieldDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Apply", isOn: applyBinding)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Apply \(label) to all \(fileCount) files")
                    .accessibilityHint(applyHint)

                Spacer()

                if field.isApplied, field.text.isEmpty {
                    Text("Will remove from all files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: textBinding)
                    .font(.body)
                    .frame(minHeight: minimumHeight)
                    .accessibilityLabel(label)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityHint(textFieldHint)

                if shouldShowMixedPrompt {
                    Text("Multiple Values")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { field.text },
            set: { newValue in
                var updated = field
                updated.text = newValue
                field = updated
            }
        )
    }

    private var applyBinding: Binding<Bool> {
        Binding(
            get: { field.isApplied },
            set: { newValue in
                var updated = field
                updated.isApplied = newValue
                field = updated
            }
        )
    }

    private var shouldShowMixedPrompt: Bool {
        !field.isApplied && field.source == .mixed && field.text.isEmpty
    }

    private var accessibilityValue: String {
        if shouldShowMixedPrompt {
            return "Multiple Values"
        }
        if field.text.isEmpty {
            return field.isApplied ? "Empty; will be removed" : "Empty"
        }
        return field.text
    }

    private var textFieldHint: String {
        field.isApplied
            ? "This value will be applied to all \(fileCount) files"
            : "Editing automatically marks this field Apply"
    }

    private var applyHint: String {
        if field.isApplied, field.text.isEmpty {
            return "This field will be removed from all selected files"
        }
        return field.isApplied
            ? "This field will be applied to all selected files"
            : "Each file will keep its existing value"
    }
}
