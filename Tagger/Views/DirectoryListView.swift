import SwiftUI

struct DirectoryListView: View {
    @Bindable var session: LibrarySession
    // Track tentative List selection so cancelled navigation can restore the highlight.
    @State private var displayedSelection: Set<URL> = []

    var body: some View {
        List(selection: selection) {
            ForEach(session.entries) { entry in
                DirectoryEntryRow(entry: entry)
                    .tag(entry.url)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        session.openDirectoryEntry(entry)
                    }
                    .contextMenu {
                        if entry.kind == .folder {
                            Button("Open") {
                                session.openDirectoryEntry(entry)
                            }
                        }
                    }
            }
        }
        .disabled(session.isSaving)
        .onAppear {
            displayedSelection = session.selectedEntryURLs
        }
        .onChange(of: session.selectedEntryURLs) { _, selection in
            displayedSelection = selection
        }
        .onChange(of: session.isShowingUnsavedChangesAlert) { _, isShowing in
            if !isShowing {
                displayedSelection = session.selectedEntryURLs
            }
        }
        .onChange(of: displayedSelection) { _, _ in
            if !session.isShowingUnsavedChangesAlert {
                displayedSelection = session.selectedEntryURLs
            }
        }
        .overlay {
            if session.isLoadingDirectory {
                ProgressView("Loading folder…")
                    .padding()
            } else if session.rootURL != nil, session.entries.isEmpty {
                ContentUnavailableView(
                    "No Audio Files",
                    systemImage: "music.note",
                    description: Text("This folder has no subfolders, MP3 files, or M4A files.")
                )
            } else if session.rootURL == nil {
                ContentUnavailableView(
                    "Choose a Folder",
                    systemImage: "folder",
                    description: Text("Folders, MP3 files, and M4A files will appear here.")
                )
            }
        }
        .navigationTitle(session.selectedFolderURL?.lastPathComponent ?? "Files")
    }

    private var selection: Binding<Set<URL>> {
        Binding(
            get: { displayedSelection },
            set: { newValue in
                displayedSelection = newValue
                session.requestSelectEntries(newValue)
            }
        )
    }
}

private struct DirectoryEntryRow: View {
    let entry: DirectoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == .folder ? "folder.fill" : "music.note")
                .foregroundStyle(entry.kind == .folder ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)

                if let fileSize = entry.fileSize {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(fileSize),
                        countStyle: .file
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
