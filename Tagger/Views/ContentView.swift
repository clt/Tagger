import SwiftUI

struct ContentView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        NavigationSplitView {
            FolderTreeView(session: session)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } content: {
            DirectoryListView(session: session)
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 460)
        } detail: {
            TagEditorView(session: session)
                .navigationSplitViewColumnWidth(min: 430, ideal: 590)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    session.chooseFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .disabled(session.isSaving)
                .help("Choose a folder of MP3 files")

                Button {
                    session.revert()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(!session.canRevert)
                .help("Revert unsaved changes")

                Button {
                    Task { await session.save() }
                } label: {
                    if session.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(session.saveButtonTitle, systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(!session.canSave)
                .help(session.saveButtonTitle)
            }
        }
        .alert(item: $session.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            "Save changes before continuing?",
            isPresented: $session.isShowingUnsavedChangesAlert
        ) {
            Button("Save") {
                session.saveAndContinuePendingNavigation()
            }
            Button("Discard Changes", role: .destructive) {
                session.discardAndContinuePendingNavigation()
            }
            Button("Cancel", role: .cancel) {
                session.cancelPendingNavigation()
            }
        } message: {
            Text(session.unsavedChangesMessage)
        }
        .focusedSceneValue(
            \.taggerCommandActions,
            TaggerCommandActions(
                openFolder: { session.chooseFolder() },
                save: { Task { await session.save() } },
                revert: { session.revert() },
                canSave: session.canSave,
                canRevert: session.canRevert
            )
        )
    }
}
