import AppKit
import Foundation

@MainActor
struct FolderPicker {
    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder of MP3 Files"
        panel.message = "Tagger will show MP3 files in this folder and its subfolders."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }
}
