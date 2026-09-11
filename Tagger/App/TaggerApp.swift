import SwiftUI

@main
struct TaggerApp: App {
    @NSApplicationDelegateAdaptor(TaggerApplicationDelegate.self)
    private var applicationDelegate
    private let autoTaggingService: any AutoTaggingServicing = AutoTaggingService()

    var body: some Scene {
        WindowGroup("Tagger", id: "main") {
            TaggerWindow(autoTaggingService: autoTaggingService)
        }
        .defaultSize(width: 1_240, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            TaggerCommands()
        }
    }
}

private struct TaggerWindow: View {
    @State private var session: LibrarySession

    init(autoTaggingService: any AutoTaggingServicing) {
        _session = State(
            initialValue: LibrarySession(autoTaggingService: autoTaggingService)
        )
    }

    var body: some View {
        ContentView(session: session)
            .frame(minWidth: 900, minHeight: 420)
            .background { WindowVisibleFrameGuard() }
            .background {
                WindowCloseGuard(session: session, isDirty: session.isDirty)
            }
            .task {
                session.restoreLastFolderIfAvailable()
            }
    }
}
