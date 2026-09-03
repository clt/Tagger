import SwiftUI

struct TaggerCommandActions {
    let openFolder: @MainActor () -> Void
    let save: @MainActor () -> Void
    let revert: @MainActor () -> Void
    let canSave: Bool
    let canRevert: Bool
}

private struct TaggerCommandActionsKey: FocusedValueKey {
    typealias Value = TaggerCommandActions
}

extension FocusedValues {
    var taggerCommandActions: TaggerCommandActions? {
        get { self[TaggerCommandActionsKey.self] }
        set { self[TaggerCommandActionsKey.self] = newValue }
    }
}

struct TaggerCommands: Commands {
    @FocusedValue(\.taggerCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                actions?.openFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                actions?.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(actions?.canSave != true)

            Button("Revert to Saved") {
                actions?.revert()
            }
            .disabled(actions?.canRevert != true)
        }
    }
}
