import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    var rootURL: URL?
    var selectedFolderURL: URL?
    var selectedEntryURL: URL?
    var selectedFileURL: URL?

    var entries: [DirectoryEntry] = []
    var childFoldersByURL: [URL: [FolderItem]] = [:]
    var expandedFolders: Set<URL> = []
    var loadingChildFolders: Set<URL> = []

    var loadedTag: LoadedID3Tag?
    var draft: ID3TagDraft?
    var originalDraft: ID3TagDraft?

    var isShowingUnsavedChangesAlert = false
    var isLoadingDirectory = false
    var isLoadingTag = false
    var isSaving = false
    var statusMessage: String?
    var presentedError: PresentedError?

    @ObservationIgnored private let fileSystem: FileSystemService
    @ObservationIgnored private let metadataService: ID3MetadataService
    @ObservationIgnored private let folderAccess: FolderAccessService
    @ObservationIgnored private let folderPicker: FolderPicker
    @ObservationIgnored private var directoryLoadTask: Task<Void, Never>?
    @ObservationIgnored private var tagLoadTask: Task<Void, Never>?
    @ObservationIgnored private var folderLoadTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingNavigation: PendingNavigation?
    @ObservationIgnored private var didAttemptRestore = false
    @ObservationIgnored private var libraryGeneration = 0

    init(
        fileSystem: FileSystemService = FileSystemService(),
        metadataService: ID3MetadataService = ID3MetadataService(),
        folderAccess: FolderAccessService = FolderAccessService(),
        folderPicker: FolderPicker = FolderPicker()
    ) {
        self.fileSystem = fileSystem
        self.metadataService = metadataService
        self.folderAccess = folderAccess
        self.folderPicker = folderPicker
    }

    var isDirty: Bool {
        guard let draft, let originalDraft else { return false }
        return draft != originalDraft
    }

    var validationMessage: String? {
        draft?.validationMessage
    }

    var canSave: Bool {
        isDirty && validationMessage == nil && !isSaving && !isLoadingTag
    }

    var canRevert: Bool {
        isDirty && !isSaving
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

    func requestSelectEntry(_ entry: DirectoryEntry) {
        switch entry.kind {
        case .folder:
            request(.folderEntry(entry.url))
        case .mp3:
            requestSelectFile(entry.url)
        }
    }

    func openDirectoryEntry(_ entry: DirectoryEntry) {
        guard entry.kind == .folder else { return }
        requestSelectFolder(entry.url)
    }

    func requestSelectFile(_ url: URL) {
        guard url != selectedFileURL else { return }
        request(.file(url))
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
        guard !isSaving,
              let loadedTag,
              let draft,
              let selectedFileURL else { return false }

        let draftBeingSaved = draft

        if let validationMessage {
            presentedError = PresentedError(title: "Check Tag Values", message: validationMessage)
            return false
        }

        isSaving = true
        statusMessage = nil
        defer { isSaving = false }

        do {
            let reloaded = try await metadataService.save(
                loadedTag,
                draft: draft,
                to: selectedFileURL
            )

            guard self.selectedFileURL == selectedFileURL else { return true }
            let currentDraft = self.draft
            self.loadedTag = reloaded
            originalDraft = reloaded.draft

            if currentDraft == draftBeingSaved {
                self.draft = reloaded.draft
                statusMessage = "Saved \(selectedFileURL.lastPathComponent)"
            } else {
                // Keep edits made while disk I/O was in progress. They remain
                // dirty relative to the version that was just saved.
                statusMessage = nil
            }
            return true
        } catch {
            present(error, title: "Couldn’t Save Tags")
            return false
        }
    }

    func revert() {
        draft = originalDraft
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
            guard await save() else { return }
            perform(navigation)
        }
    }

    func discardAndContinuePendingNavigation() {
        guard !isSaving else { return }
        isShowingUnsavedChangesAlert = false
        draft = originalDraft
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

    private enum PendingNavigation {
        case root(URL)
        case folder(URL)
        case folderEntry(URL)
        case file(URL)
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
            clearSelectedTag()
            selectedEntryURL = nil
            selectedFolderURL = url
            expandedFolders.insert(url)
            loadChildFolders(of: url)
            loadDirectory(url)

        case .folderEntry(let url):
            clearSelectedTag()
            selectedEntryURL = url

        case .file(let url):
            selectedEntryURL = url
            selectedFileURL = url
            loadTag(url)
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
        selectedEntryURL = nil
        entries = []
        childFoldersByURL = [:]
        expandedFolders = [url]
        loadingChildFolders = []
        clearSelectedTag()

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

    private func loadTag(_ url: URL) {
        tagLoadTask?.cancel()
        loadedTag = nil
        draft = nil
        originalDraft = nil
        isLoadingTag = true

        tagLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await metadataService.load(from: url)
                guard !Task.isCancelled, selectedFileURL == url else { return }
                loadedTag = loaded
                draft = loaded.draft
                originalDraft = loaded.draft
            } catch is CancellationError {
                // A newer file selection replaced this request.
            } catch {
                guard selectedFileURL == url else { return }
                present(error, title: "Couldn’t Read Tags")
            }

            if selectedFileURL == url {
                isLoadingTag = false
            }
        }
    }

    private func clearSelectedTag() {
        tagLoadTask?.cancel()
        tagLoadTask = nil
        selectedFileURL = nil
        loadedTag = nil
        draft = nil
        originalDraft = nil
        isLoadingTag = false
    }

    private func cancelOutstandingWork() {
        directoryLoadTask?.cancel()
        tagLoadTask?.cancel()
        folderLoadTasks.values.forEach { $0.cancel() }
        directoryLoadTask = nil
        tagLoadTask = nil
        folderLoadTasks = [:]
        isLoadingDirectory = false
        isLoadingTag = false
    }
}
