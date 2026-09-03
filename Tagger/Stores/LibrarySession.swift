import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    var rootURL: URL?
    var selectedFolderURL: URL?
    var selectedEntryURLs: Set<URL> = []
    var selectedFileURLs: [URL] = []

    var entries: [DirectoryEntry] = []
    var childFoldersByURL: [URL: [FolderItem]] = [:]
    var expandedFolders: Set<URL> = []
    var loadingChildFolders: Set<URL> = []

    var loadedTag: LoadedID3Tag?
    var draft: ID3TagDraft?
    var originalDraft: ID3TagDraft?
    var filenameDraft: FilenameDraft?
    var loadedTagsByURL: [URL: LoadedID3Tag] = [:]
    var batchDraft: BatchID3TagDraft?

    var isShowingUnsavedChangesAlert = false
    var isLoadingDirectory = false
    var isLoadingTag = false
    var isSaving = false
    var saveProgressCompleted = 0
    var saveProgressTotal = 0
    var saveProgressFilename: String?
    var statusMessage: String?
    var presentedError: PresentedError?

    @ObservationIgnored private let fileSystem: FileSystemService
    @ObservationIgnored private let fileRenamer: any FileRenaming
    @ObservationIgnored private let metadataService: any ID3MetadataServicing
    @ObservationIgnored private let folderAccess: FolderAccessService
    @ObservationIgnored private let folderPicker: FolderPicker
    @ObservationIgnored private var directoryLoadTask: Task<Void, Never>?
    @ObservationIgnored private var tagLoadTask: Task<Void, Never>?
    @ObservationIgnored private var folderLoadTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingNavigation: PendingNavigation?
    @ObservationIgnored private var didAttemptRestore = false
    @ObservationIgnored private var libraryGeneration = 0
    @ObservationIgnored private var selectionGeneration = 0

    init(
        fileSystem: FileSystemService = FileSystemService(),
        fileRenamer: (any FileRenaming)? = nil,
        metadataService: any ID3MetadataServicing = ID3MetadataService(),
        folderAccess: FolderAccessService = FolderAccessService(),
        folderPicker: FolderPicker = FolderPicker()
    ) {
        self.fileSystem = fileSystem
        self.fileRenamer = fileRenamer ?? fileSystem
        self.metadataService = metadataService
        self.folderAccess = folderAccess
        self.folderPicker = folderPicker
    }

    var isDirty: Bool {
        hasUnsavedTagChanges || hasUnsavedFilenameChange
    }

    var hasUnsavedFilenameChange: Bool {
        selectedFileURLs.count == 1 && filenameDraft?.isDirty == true
    }

    var hasUnsavedTagChanges: Bool {
        if selectedFileURLs.count > 1 {
            return batchDraft?.isDirty == true
        }

        guard let draft, let originalDraft else { return false }
        return draft != originalDraft
    }

    var validationMessage: String? {
        if selectedFileURLs.count > 1 {
            return batchDraft?.validationMessage
        }
        return filenameDraft?.validationMessage ?? draft?.validationMessage
    }

    var canSave: Bool {
        isDirty && validationMessage == nil && !isSaving && !isLoadingTag
    }

    var canRevert: Bool {
        isDirty && !isSaving
    }

    var selectedFileURL: URL? {
        selectedFileURLs.count == 1 ? selectedFileURLs[0] : nil
    }

    var unsavedChangesMessage: String {
        if selectedFileURLs.count > 1 {
            return "The selected \(selectedFileURLs.count) MP3 files have unsaved tag changes."
        }

        if hasUnsavedFilenameChange, hasUnsavedTagChanges {
            return "The selected MP3 has unsaved file name and tag changes."
        }
        if hasUnsavedFilenameChange {
            return "The selected MP3 has an unsaved file name change."
        }
        return "The selected MP3 has unsaved tag changes."
    }

    var saveButtonTitle: String {
        selectedFileURLs.count > 1 ? "Save \(selectedFileURLs.count) Files" : "Save"
    }

    func restoreLastFolderIfAvailable() {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true

        do {
            guard let url = try folderAccess.restoreLastFolder() else { return }
            applyRoot(url, beginSecurityScope: false)
        } catch {
            folderAccess.forgetLastFolder()
            present(error, title: "Couldn’t Reopen Folder")
        }
    }

    func chooseFolder() {
        guard !isSaving else { return }

        if let url = folderPicker.chooseFolder() {
            requestOpenRoot(url)
        }
    }

    func requestOpenRoot(_ url: URL) {
        request(.root(url))
    }

    func requestSelectFolder(_ url: URL) {
        guard url != selectedFolderURL else { return }
        request(.folder(url))
    }

    func requestSelectEntries(_ urls: Set<URL>) {
        let selectedEntries = entries.filter { urls.contains($0.url) }
        let fileURLs = selectedEntries
            .filter { $0.kind == .mp3 }
            .map(\.url)

        if !fileURLs.isEmpty {
            let normalizedSelection = Set(fileURLs)
            guard fileURLs != selectedFileURLs else {
                selectedEntryURLs = normalizedSelection
                return
            }
            request(.files(fileURLs))
        } else if selectedEntries.count == 1, let folder = selectedEntries.first {
            request(.folderEntry(folder.url))
        } else {
            request(.clearSelection)
        }
    }

    func openDirectoryEntry(_ entry: DirectoryEntry) {
        guard entry.kind == .folder else { return }
        requestSelectFolder(entry.url)
    }

    func requestSelectFile(_ url: URL) {
        guard selectedFileURLs != [url] else { return }
        request(.files([url]))
    }

    func children(of url: URL) -> [FolderItem] {
        childFoldersByURL[url] ?? []
    }

    func isFolderExpanded(_ url: URL) -> Bool {
        expandedFolders.contains(url)
    }

    func setFolderExpanded(_ url: URL, isExpanded: Bool) {
        if isExpanded {
            expandedFolders.insert(url)
            loadChildFolders(of: url)
        } else {
            expandedFolders.remove(url)
        }
    }

    func loadChildFolders(of url: URL) {
        guard childFoldersByURL[url] == nil,
              !loadingChildFolders.contains(url) else { return }

        loadingChildFolders.insert(url)
        let generation = libraryGeneration

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let folders = try await fileSystem.childFolders(of: url)
                guard !Task.isCancelled, generation == libraryGeneration else { return }
                childFoldersByURL[url] = folders
            } catch is CancellationError {
                // A newer folder or library selection replaced this request.
            } catch {
                guard generation == libraryGeneration else { return }
                present(error, title: "Couldn’t Read Folder")
            }

            loadingChildFolders.remove(url)
            folderLoadTasks[url] = nil
        }

        folderLoadTasks[url] = task
    }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }

        if selectedFileURLs.count > 1 {
            return await saveBatch()
        }
        return await saveSingle()
    }

    private func saveSingle() async -> Bool {
        guard let loadedTag,
              let draft,
              let selectedFileURL,
              let filenameDraft else { return false }

        let draftBeingSaved = draft
        let filenameBeingSaved = filenameDraft
        let hasTagChanges = draft != originalDraft
        let hasFilenameChanges = filenameDraft.isDirty
        guard hasTagChanges || hasFilenameChanges else { return false }

        if let validationMessage {
            presentedError = PresentedError(title: "Check Changes", message: validationMessage)
            return false
        }

        isSaving = true
        statusMessage = nil
        defer { isSaving = false }

        let renameDestination: URL?
        if hasFilenameChanges {
            do {
                renameDestination = try await fileRenamer.validateRename(
                    from: selectedFileURL,
                    toFileName: filenameBeingSaved.proposedFilename
                )
            } catch {
                present(error, title: "Couldn’t Rename File")
                return false
            }
        } else {
            renameDestination = nil
        }

        var persistedTag = loadedTag
        if hasTagChanges {
            do {
                persistedTag = try await metadataService.save(
                    loadedTag,
                    draft: draftBeingSaved
                )
            } catch {
                present(error, title: "Couldn’t Save Tags")
                return false
            }
        } else if hasFilenameChanges {
            do {
                try await metadataService.validateUnchanged(loadedTag)
            } catch {
                present(error, title: "Couldn’t Rename File")
                return false
            }
        }

        if let renameDestination {
            do {
                try await fileRenamer.rename(
                    from: selectedFileURL,
                    to: renameDestination
                )
            } catch {
                guard self.selectedFileURL == selectedFileURL else { return false }
                if hasTagChanges {
                    applyPersistedTag(persistedTag, draftBeingSaved: draftBeingSaved)
                    presentedError = PresentedError(
                        title: "Tags Saved, File Not Renamed",
                        message: "The ID3 tags were saved, but the file name wasn’t changed. \(error.localizedDescription)"
                    )
                } else {
                    present(error, title: "Couldn’t Rename File")
                }
                return false
            }
        }

        guard self.selectedFileURL == selectedFileURL else { return true }
        let draftStayedUnchanged = self.draft == draftBeingSaved
        let filenameStayedUnchanged = self.filenameDraft == filenameBeingSaved

        if hasTagChanges {
            applyPersistedTag(persistedTag, draftBeingSaved: draftBeingSaved)
        }

        let finalURL: URL
        if let renameDestination {
            finalURL = renameDestination
            applySuccessfulRename(
                from: selectedFileURL,
                to: renameDestination,
                loadedTag: persistedTag,
                filenameBeingSaved: filenameBeingSaved
            )
        } else {
            finalURL = selectedFileURL
        }

        if draftStayedUnchanged, filenameStayedUnchanged {
            if hasFilenameChanges, !hasTagChanges {
                statusMessage = "Renamed to \(finalURL.lastPathComponent)"
            } else {
                statusMessage = "Saved \(finalURL.lastPathComponent)"
            }
        } else {
            // Preserve edits made while disk I/O was in progress. They remain
            // dirty relative to the version that was just persisted.
            statusMessage = nil
        }
        return true
    }

    private func saveBatch() async -> Bool {
        guard selectedFileURLs.count > 1,
              let batchDraft,
              batchDraft.isDirty else { return false }

        if let validationMessage {
            presentedError = PresentedError(title: "Check Tag Values", message: validationMessage)
            return false
        }

        let urls = selectedFileURLs
        let draftBeingSaved = batchDraft
        guard urls.allSatisfy({ loadedTagsByURL[$0] != nil }) else {
            presentedError = PresentedError(
                title: "Couldn’t Save Tags",
                message: "Reload the selection before saving."
            )
            return false
        }

        isSaving = true
        saveProgressCompleted = 0
        saveProgressTotal = urls.count
        saveProgressFilename = urls.first?.lastPathComponent
        statusMessage = nil
        defer {
            isSaving = false
            saveProgressCompleted = 0
            saveProgressTotal = 0
            saveProgressFilename = nil
        }

        var updatedTags = loadedTagsByURL
        var failures: [(url: URL, message: String)] = []
        var successCount = 0

        for (index, url) in urls.enumerated() {
            saveProgressFilename = url.lastPathComponent

            guard let loaded = updatedTags[url] else {
                failures.append((url, "The loaded tag data is unavailable."))
                saveProgressCompleted = index + 1
                continue
            }

            do {
                let updatedDraft = draftBeingSaved.applying(to: loaded.draft)
                let reloaded = try await metadataService.save(loaded, draft: updatedDraft)
                updatedTags[url] = reloaded
                successCount += 1
            } catch {
                failures.append((url, error.localizedDescription))
            }

            saveProgressCompleted = index + 1
        }

        guard selectedFileURLs == urls else { return failures.isEmpty }
        loadedTagsByURL = updatedTags

        if !failures.isEmpty {
            if let currentBatchDraft = self.batchDraft {
                self.batchDraft = rebase(
                    currentBatchDraft,
                    on: updatedTags,
                    urls: urls
                )
            }
            statusMessage = successCount == 0
                ? "No files were saved"
                : "Saved \(successCount) of \(urls.count) files"
            presentedError = PresentedError(
                title: "Some Tags Weren’t Saved",
                message: batchFailureMessage(
                    successes: successCount,
                    total: urls.count,
                    failures: failures
                )
            )
            return false
        }

        if self.batchDraft == draftBeingSaved {
            self.batchDraft = makeBatchDraft(from: updatedTags, urls: urls)
            statusMessage = "Saved tags in \(urls.count) files"
        }
        return true
    }

    func revert() {
        if selectedFileURLs.count > 1 {
            batchDraft = makeBatchDraft(from: loadedTagsByURL, urls: selectedFileURLs)
        } else {
            draft = originalDraft
            filenameDraft?.revert()
        }
        statusMessage = nil
    }

    func replaceArtwork(with data: Data) {
        draft?.artworkData = data
        statusMessage = nil
    }

    func removeArtwork() {
        draft?.artworkData = nil
        statusMessage = nil
    }

    func saveAndContinuePendingNavigation() {
        isShowingUnsavedChangesAlert = false
        guard !isSaving, let navigation = pendingNavigation else { return }
        pendingNavigation = nil

        Task {
            guard await save(), !isDirty else { return }
            perform(navigation)
        }
    }

    func discardAndContinuePendingNavigation() {
        guard !isSaving else { return }
        isShowingUnsavedChangesAlert = false
        revert()
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        perform(pendingNavigation)
    }

    func cancelPendingNavigation() {
        isShowingUnsavedChangesAlert = false
        pendingNavigation = nil
    }

    func present(_ error: Error, title: String) {
        presentedError = PresentedError(title: title, message: error.localizedDescription)
    }

    private func applyPersistedTag(
        _ persistedTag: LoadedID3Tag,
        draftBeingSaved: ID3TagDraft
    ) {
        let currentDraft = draft
        loadedTag = persistedTag
        originalDraft = persistedTag.draft
        if loadedTagsByURL[persistedTag.url] != nil {
            loadedTagsByURL[persistedTag.url] = persistedTag
        }
        if currentDraft == draftBeingSaved {
            draft = persistedTag.draft
        }
    }

    private func applySuccessfulRename(
        from sourceURL: URL,
        to destinationURL: URL,
        loadedTag persistedTag: LoadedID3Tag,
        filenameBeingSaved: FilenameDraft
    ) {
        let currentFilenameDraft = filenameDraft
        let relocatedTag = persistedTag.relocated(to: destinationURL)

        if let index = entries.firstIndex(where: { $0.url == sourceURL }) {
            let sourceEntry = entries[index]
            entries[index] = DirectoryEntry(
                url: destinationURL,
                name: destinationURL.lastPathComponent,
                kind: sourceEntry.kind,
                fileSize: persistedTag.snapshot.fileSize
            )
            entries.sort(by: DirectoryEntry.areInDisplayOrder)
        }

        selectedEntryURLs.remove(sourceURL)
        selectedEntryURLs.insert(destinationURL)
        selectedFileURLs = [destinationURL]
        loadedTag = relocatedTag

        if loadedTagsByURL.removeValue(forKey: sourceURL) != nil {
            loadedTagsByURL[destinationURL] = relocatedTag
        }

        var rebasedFilename = FilenameDraft(url: destinationURL)
        if currentFilenameDraft != filenameBeingSaved,
           let currentFilenameDraft {
            rebasedFilename.stem = currentFilenameDraft.stem
        }
        filenameDraft = rebasedFilename
    }

    private func makeBatchDraft(
        from tags: [URL: LoadedID3Tag],
        urls: [URL]
    ) -> BatchID3TagDraft? {
        let drafts = urls.compactMap { tags[$0]?.draft }
        guard drafts.count == urls.count else { return nil }
        return BatchID3TagDraft(drafts: drafts)
    }

    private func rebase(
        _ batchDraft: BatchID3TagDraft,
        on tags: [URL: LoadedID3Tag],
        urls: [URL]
    ) -> BatchID3TagDraft? {
        let drafts = urls.compactMap { tags[$0]?.draft }
        guard drafts.count == urls.count else { return nil }
        return batchDraft.rebased(on: drafts)
    }

    private func batchFailureMessage(
        successes: Int,
        total: Int,
        failures: [(url: URL, message: String)]
    ) -> String {
        var lines = ["Saved \(successes) of \(total) files. Review the failures before retrying the remaining edits."]
        lines.append(contentsOf: failures.prefix(8).map {
            "\($0.url.lastPathComponent): \($0.message)"
        })
        if failures.count > 8 {
            lines.append("…and \(failures.count - 8) more.")
        }
        return lines.joined(separator: "\n")
    }

    private enum PendingNavigation {
        case root(URL)
        case folder(URL)
        case folderEntry(URL)
        case files([URL])
        case clearSelection
    }

    private func request(_ navigation: PendingNavigation) {
        guard !isSaving else { return }

        if isDirty {
            pendingNavigation = navigation
            isShowingUnsavedChangesAlert = true
        } else {
            perform(navigation)
        }
    }

    private func perform(_ navigation: PendingNavigation) {
        statusMessage = nil

        switch navigation {
        case .root(let url):
            applyRoot(url, beginSecurityScope: true)

        case .folder(let url):
            clearSelectedTags()
            selectedFolderURL = url
            expandedFolders.insert(url)
            loadChildFolders(of: url)
            loadDirectory(url)

        case .folderEntry(let url):
            clearSelectedTags()
            selectedEntryURLs = [url]

        case .files(let urls):
            selectedEntryURLs = Set(urls)
            selectedFileURLs = urls
            loadTags(urls)

        case .clearSelection:
            clearSelectedTags()
        }
    }

    private func applyRoot(_ url: URL, beginSecurityScope: Bool) {
        libraryGeneration += 1
        cancelOutstandingWork()

        if beginSecurityScope {
            do {
                try folderAccess.beginAccessing(url)
            } catch {
                present(error, title: "Couldn’t Remember Folder")
            }
        }

        rootURL = url
        selectedFolderURL = url
        entries = []
        childFoldersByURL = [:]
        expandedFolders = [url]
        loadingChildFolders = []
        clearSelectedTags()

        loadChildFolders(of: url)
        loadDirectory(url)
    }

    private func loadDirectory(_ url: URL) {
        directoryLoadTask?.cancel()
        isLoadingDirectory = true
        entries = []
        let generation = libraryGeneration

        directoryLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedEntries = try await fileSystem.contents(of: url)
                guard !Task.isCancelled,
                      generation == libraryGeneration,
                      selectedFolderURL == url else { return }
                entries = loadedEntries
            } catch is CancellationError {
                // A newer directory selection replaced this request.
            } catch {
                guard !Task.isCancelled,
                      generation == libraryGeneration,
                      selectedFolderURL == url else { return }
                present(error, title: "Couldn’t Read Folder")
            }

            if generation == libraryGeneration, selectedFolderURL == url {
                isLoadingDirectory = false
            }
        }
    }

    private func loadTags(_ urls: [URL]) {
        tagLoadTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        resetLoadedTagState()
        isLoadingTag = true

        tagLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var loadedByURL: [URL: LoadedID3Tag] = [:]
                loadedByURL.reserveCapacity(urls.count)

                for url in urls {
                    try Task.checkCancellation()
                    do {
                        loadedByURL[url] = try await metadataService.load(from: url)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if urls.count == 1 {
                            throw error
                        }
                        throw SelectedTagLoadError(
                            filename: url.lastPathComponent,
                            reason: error.localizedDescription
                        )
                    }
                }

                guard !Task.isCancelled,
                      generation == selectionGeneration,
                      selectedFileURLs == urls else { return }

                loadedTagsByURL = loadedByURL

                if urls.count == 1, let loaded = loadedByURL[urls[0]] {
                    loadedTag = loaded
                    draft = loaded.draft
                    originalDraft = loaded.draft
                    filenameDraft = FilenameDraft(url: urls[0])
                } else {
                    batchDraft = makeBatchDraft(from: loadedByURL, urls: urls)
                }
            } catch is CancellationError {
                // A newer selection replaced this request.
            } catch {
                guard generation == selectionGeneration,
                      selectedFileURLs == urls else { return }
                resetLoadedTagState()
                present(error, title: "Couldn’t Read Tags")
            }

            if generation == selectionGeneration, selectedFileURLs == urls {
                isLoadingTag = false
            }
        }
    }

    private func clearSelectedTags() {
        tagLoadTask?.cancel()
        tagLoadTask = nil
        selectionGeneration += 1
        selectedEntryURLs = []
        selectedFileURLs = []
        resetLoadedTagState()
        isLoadingTag = false
    }

    private func resetLoadedTagState() {
        loadedTag = nil
        draft = nil
        originalDraft = nil
        filenameDraft = nil
        loadedTagsByURL = [:]
        batchDraft = nil
    }

    private func cancelOutstandingWork() {
        directoryLoadTask?.cancel()
        tagLoadTask?.cancel()
        selectionGeneration += 1
        folderLoadTasks.values.forEach { $0.cancel() }
        directoryLoadTask = nil
        tagLoadTask = nil
        folderLoadTasks = [:]
        isLoadingDirectory = false
        isLoadingTag = false
    }
}

private struct SelectedTagLoadError: LocalizedError {
    let filename: String
    let reason: String

    var errorDescription: String? {
        "\(filename) could not be loaded. Deselect it before batch editing. \(reason)"
    }
}
