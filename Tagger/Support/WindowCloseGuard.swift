import AppKit
import SwiftUI

@MainActor
final class TaggerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowCloseRegistry.shared.applicationShouldTerminate(sender)
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let session: LibrarySession
    let isDirty: Bool

    func makeCoordinator() -> WindowCloseCoordinator {
        WindowCloseCoordinator(session: session)
    }

    func makeNSView(context: Context) -> WindowReferenceView {
        let view = WindowReferenceView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowReferenceView, context: Context) {
        context.coordinator.updateDocumentEdited(isDirty)
    }

    static func dismantleNSView(_ nsView: WindowReferenceView, coordinator: WindowCloseCoordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }
}

@MainActor
final class WindowReferenceView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

@MainActor
final class WindowCloseCoordinator: NSObject, NSWindowDelegate {
    private enum DecisionContext {
        case window
        case application
    }

    let session: LibrarySession

    private weak var window: NSWindow?
    // NSObject message forwarding is nonisolated, while AppKit delegate traffic
    // is confined to the main thread. This unsafe annotation is limited to the
    // forwarding reference so SwiftUI's existing window delegate remains intact.
    nonisolated(unsafe) private weak var previousDelegate: (any NSWindowDelegate)?
    private var bypassNextClose = false
    private(set) var isResolvingDecision = false

    init(session: LibrarySession) {
        self.session = session
    }

    func attach(to newWindow: NSWindow?) {
        guard window !== newWindow else { return }
        detach()

        guard let newWindow else { return }
        window = newWindow
        previousDelegate = newWindow.delegate
        newWindow.delegate = self
        newWindow.isDocumentEdited = session.isDirty
        WindowCloseRegistry.shared.register(self)
    }

    func detach() {
        guard let window else {
            WindowCloseRegistry.shared.unregister(self)
            return
        }

        if window.delegate === self {
            window.delegate = previousDelegate
        }
        WindowCloseRegistry.shared.unregister(self)
        self.window = nil
        previousDelegate = nil
    }

    func updateDocumentEdited(_ isDirty: Bool) {
        window?.isDocumentEdited = isDirty
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassNextClose {
            bypassNextClose = false
            return previousDelegateAllowsClose(sender)
        }

        guard !session.isSaving else {
            NSSound.beep()
            return false
        }

        guard session.isDirty else {
            return previousDelegateAllowsClose(sender)
        }

        resolveUnsavedChanges(in: .window) { [weak self] shouldClose in
            guard shouldClose, let self, let window = self.window else { return }
            window.isDocumentEdited = false
            self.bypassNextClose = true
            window.performClose(nil)
        }
        return false
    }

    func resolveForApplicationTermination(
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        resolveUnsavedChanges(in: .application, completion: completion)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to: selector) == true {
            return previousDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    private func resolveUnsavedChanges(
        in context: DecisionContext,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !session.isSaving else {
            NSSound.beep()
            completion(false)
            return
        }

        guard session.isDirty else {
            completion(true)
            return
        }

        guard !isResolvingDecision, let window else {
            completion(false)
            return
        }

        isResolvingDecision = true
        window.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        switch context {
        case .window:
            alert.messageText = "Save changes before closing?"
        case .application:
            alert.messageText = "Save changes before quitting Tagger?"
        }

        if let filename = session.selectedFileURL?.lastPathComponent {
            alert.informativeText = "The ID3 tags for \(filename) have unsaved changes."
        } else {
            alert.informativeText = "The selected MP3 has unsaved ID3 tag changes."
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        let discardButton = alert.addButton(withTitle: "Discard")
        discardButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else {
                    completion(false)
                    return
                }
                self.handle(response, completion: completion)
            }
        }
    }

    private func handle(
        _ response: NSApplication.ModalResponse,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                let didSave = await session.save()
                isResolvingDecision = false
                window?.isDocumentEdited = session.isDirty
                completion(didSave && !session.isDirty)
            }

        case .alertSecondButtonReturn:
            session.revert()
            isResolvingDecision = false
            window?.isDocumentEdited = false
            completion(true)

        default:
            isResolvingDecision = false
            completion(false)
        }
    }

    private func previousDelegateAllowsClose(_ sender: NSWindow) -> Bool {
        previousDelegate?.windowShouldClose?(sender) ?? true
    }
}

@MainActor
private final class WindowCloseRegistry {
    static let shared = WindowCloseRegistry()

    private struct WeakCoordinator {
        weak var value: WindowCloseCoordinator?
    }

    private var coordinators: [ObjectIdentifier: WeakCoordinator] = [:]
    private var isResolvingApplicationTermination = false

    func register(_ coordinator: WindowCloseCoordinator) {
        coordinators[ObjectIdentifier(coordinator)] = WeakCoordinator(value: coordinator)
    }

    func unregister(_ coordinator: WindowCloseCoordinator) {
        coordinators[ObjectIdentifier(coordinator)] = nil
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        let liveCoordinators = currentCoordinators()

        guard !isResolvingApplicationTermination else {
            return .terminateLater
        }

        guard !liveCoordinators.contains(where: {
            $0.session.isSaving || $0.isResolvingDecision
        }) else {
            NSSound.beep()
            return .terminateCancel
        }

        let dirtyCoordinators = liveCoordinators.filter(\.session.isDirty)
        guard !dirtyCoordinators.isEmpty else {
            return .terminateNow
        }

        isResolvingApplicationTermination = true
        resolveApplicationTermination(
            dirtyCoordinators,
            at: 0,
            application: application
        )
        return .terminateLater
    }

    private func currentCoordinators() -> [WindowCloseCoordinator] {
        coordinators = coordinators.filter { $0.value.value != nil }
        return coordinators.values.compactMap(\.value)
    }

    private func resolveApplicationTermination(
        _ coordinators: [WindowCloseCoordinator],
        at index: Int,
        application: NSApplication
    ) {
        guard index < coordinators.count else {
            finishApplicationTermination(true, application: application)
            return
        }

        let coordinator = coordinators[index]
        guard coordinator.session.isDirty else {
            resolveApplicationTermination(coordinators, at: index + 1, application: application)
            return
        }

        coordinator.resolveForApplicationTermination { [weak self] shouldContinue in
            guard let self else {
                application.reply(toApplicationShouldTerminate: false)
                return
            }

            guard shouldContinue else {
                self.finishApplicationTermination(false, application: application)
                return
            }

            self.resolveApplicationTermination(
                coordinators,
                at: index + 1,
                application: application
            )
        }
    }

    private func finishApplicationTermination(
        _ shouldTerminate: Bool,
        application: NSApplication
    ) {
        isResolvingApplicationTermination = false
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }
}
