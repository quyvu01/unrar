import AppKit
import ArchiveKit
import SwiftUI

@main
struct UnrarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Unrar", id: "archive", for: URL.self) { $url in
            ContentView(initialURL: url)
                .frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 980, height: 620)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Receives files opened from Finder ("Open With", double click, Dock icon drop).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When started with `swift run` the process is not a bundled app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRouter.shared.enqueue(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Hands URLs opened through the app delegate to SwiftUI windows.
@MainActor
@Observable
final class OpenRouter {
    static let shared = OpenRouter()

    private(set) var pending: [URL] = []

    func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls)
    }

    func takeAll() -> [URL] {
        let urls = pending
        pending = []
        return urls
    }
}

// MARK: - Focused window model

struct ArchiveModelKey: FocusedValueKey {
    typealias Value = ArchiveViewModel
}

extension FocusedValues {
    var archiveModel: ArchiveViewModel? {
        get { self[ArchiveModelKey.self] }
        set { self[ArchiveModelKey.self] = newValue }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.archiveModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Archive…") {
                guard let url = ArchivePanels.chooseArchive() else { return }
                if let model, model.archive == nil {
                    model.open(url)
                } else {
                    openWindow(id: "archive", value: url)
                }
            }
            .keyboardShortcut("o")

            Button("New Window") {
                openWindow(id: "archive")
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Archive") {
            Button("Extract") {
                if let model { ArchiveActions.extract(model: model, askDestination: false) }
            }
            .keyboardShortcut("e")
            .disabled(model?.archive == nil || model?.isBusy == true)

            Button("Extract To…") {
                if let model { ArchiveActions.extract(model: model, askDestination: true) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model?.archive == nil || model?.isBusy == true)

            Button("Test Archive") {
                model?.test()
            }
            .keyboardShortcut("t")
            .disabled(model?.archive == nil || model?.isBusy == true)

            Divider()

            Button("Enclosing Folder") {
                model?.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model?.canGoUp != true)

            Button("Back") {
                model?.goBack()
            }
            .keyboardShortcut("[")
            .disabled(model?.canGoBack != true)

            Button("Forward") {
                model?.goForward()
            }
            .keyboardShortcut("]")
            .disabled(model?.canGoForward != true)

            Divider()

            Button("Show Archive in Finder") {
                if let url = model?.archive?.url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model?.archive == nil)
        }
    }
}

// MARK: - Shared actions

@MainActor
enum ArchiveActions {
    /// Extracts the selection (or everything) using the user's destination settings.
    static func extract(model: ArchiveViewModel, askDestination: Bool, selectionOnly: Bool = true) {
        let settings = ExtractionSettings.current
        let scope = model.extractionScope(selectionOnly: selectionOnly)
        var destination = askDestination ? nil : model.defaultDestination(settings: settings)
        if destination == nil {
            let suggested = model.archive?.url.deletingLastPathComponent()
            guard let chosen = ArchivePanels.chooseDestination(startingAt: suggested) else { return }
            destination = chosen
        }
        guard let destination else { return }
        model.extract(paths: scope.paths, to: destination, stripPrefix: scope.stripPrefix, settings: settings)
    }
}

@MainActor
enum ArchivePanels {
    static func chooseArchive() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Archive")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ArchiveTypes.openable
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDestination(startingAt folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Destination Folder")
        panel.prompt = String(localized: "Extract Here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        return panel.runModal() == .OK ? panel.url : nil
    }
}
