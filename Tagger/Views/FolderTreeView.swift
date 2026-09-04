import SwiftUI

struct FolderTreeView: View {
    @Bindable var session: LibrarySession
    // Track tentative List selection so cancelled navigation can restore the highlight.
    @State private var displayedSelection: URL?

    var body: some View {
        Group {
            if let rootURL = session.rootURL {
                List(selection: selection) {
                    FolderTreeNodeView(url: rootURL, session: session)
                }
                .listStyle(.sidebar)
                .disabled(session.isSaving)
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
        .onAppear {
            displayedSelection = session.selectedFolderURL
        }
        .onChange(of: session.selectedFolderURL) { _, selection in
            displayedSelection = selection
        }
        .onChange(of: session.isShowingUnsavedChangesAlert) { _, isShowing in
            if !isShowing {
                displayedSelection = session.selectedFolderURL
            }
        }
        .onChange(of: displayedSelection) { _, _ in
            if !session.isShowingUnsavedChangesAlert {
                displayedSelection = session.selectedFolderURL
            }
        }
        .navigationTitle("Folders")
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { displayedSelection },
            set: { newValue in
                displayedSelection = newValue
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
