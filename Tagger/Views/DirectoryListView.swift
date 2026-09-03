import SwiftUI

struct DirectoryListView: View {
    @Bindable var session: LibrarySession

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
        .overlay {
            if session.isLoadingDirectory {
                ProgressView("Loading folder…")
                    .padding()
            } else if session.rootURL != nil, session.entries.isEmpty {
                ContentUnavailableView(
                    "No MP3 Files",
                    systemImage: "music.note",
                    description: Text("This folder has no subfolders or MP3 files.")
                )
            } else if session.rootURL == nil {
                ContentUnavailableView(
                    "Choose a Folder",
                    systemImage: "folder",
                    description: Text("Folders and MP3 files will appear here.")
                )
            }
        }
        .navigationTitle(session.selectedFolderURL?.lastPathComponent ?? "Files")
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { session.selectedEntryURL },
            set: { newValue in
                guard let newValue,
                      let entry = session.entries.first(where: { $0.url == newValue }) else {
                    return
                }
                session.requestSelectEntry(entry)
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
