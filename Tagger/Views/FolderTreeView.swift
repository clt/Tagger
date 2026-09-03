import SwiftUI

struct FolderTreeView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Group {
            if let rootURL = session.rootURL {
                List(selection: selection) {
                    FolderTreeNodeView(url: rootURL, session: session)
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "folder")
                } description: {
                    Text("Choose a folder to browse its MP3 files.")
                } actions: {
                    Button("Open Folder…") {
                        session.chooseFolder()
                    }
                }
            }
        }
        .navigationTitle("Folders")
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { session.selectedFolderURL },
            set: { newValue in
                if let newValue {
                    session.requestSelectFolder(newValue)
                }
            }
        )
    }
}

private struct FolderTreeNodeView: View {
    let url: URL
    @Bindable var session: LibrarySession

    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            if session.loadingChildFolders.contains(url) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(session.children(of: url)) { child in
                FolderTreeNodeView(url: child.url, session: session)
            }
        } label: {
            Label(url.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
        }
        .tag(url)
        .onAppear {
            if session.isFolderExpanded(url) {
                session.loadChildFolders(of: url)
            }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { session.isFolderExpanded(url) },
            set: { session.setFolderExpanded(url, isExpanded: $0) }
        )
    }
}
