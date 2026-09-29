import SwiftUI

struct ContentView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        NavigationSplitView {
            FolderTreeView(session: session)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 0) {
                    if session.rootURL != nil {
                        FolderMetadataSummaryView(
                            summary: session.folderMetadataSummary,
                            isLoading: session.isLoadingDirectory || session.isLoadingFolderSummary,
                            hasUnsavedChanges: session.folderSummaryHasUnsavedChanges,
                            artworkSize: min(128, max(88, geometry.size.height * 0.18))
                        )
                        Divider()
                    }

                    HSplitView {
                        DirectoryListView(session: session)
                            .frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
                            .frame(maxHeight: .infinity)
                        TagEditorView(session: session)
                            .frame(minWidth: 430, idealWidth: 590, maxWidth: .infinity)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .navigationSplitViewColumnWidth(min: 671, ideal: 910)
            .navigationTitle(session.selectedFolderURL?.lastPathComponent ?? "Tagger")
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(
            isPresented: $session.isShowingAutoTagSheet,
            onDismiss: { session.autoTagSheetDidDismiss() }
        ) {
            AutoTagReviewView(session: session)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    session.chooseFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .disabled(session.isSaving)
                .help("Choose a folder of MP3 and M4A files")

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
                findTags: { session.startAutoTagSearch() },
                save: { Task { await session.save() } },
                revert: { session.revert() },
                canFindTags: session.canFindTags,
                canSave: session.canSave,
                canRevert: session.canRevert
            )
        )
    }
}
