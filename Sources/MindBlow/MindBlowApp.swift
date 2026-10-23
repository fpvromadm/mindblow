import SwiftUI

@main
struct MindBlowApp: App {
    init() {
        // Default save location: local ~/Documents (not iCloud Drive).
        // NSNavLastRootDirectory only seeds the save panel until the user
        // picks a folder themselves; their last choice wins afterwards.
        UserDefaults.standard.register(defaults: [
            "NSDocumentSaveNewDocumentsToCloud": false,
            "NSNavLastRootDirectory": "~/Documents",
        ])
    }

    var body: some Scene {
        DocumentGroup(newDocument: MindMapDocument()) { file in
            EditorView(document: file.$document)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { MapMenuCommands() }
    }
}
