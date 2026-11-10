import ArchiveKit
import SwiftUI

struct ContentView: View {
    let initialURL: URL?

    @State private var model = ArchiveViewModel()
    @State private var isDropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.state {
            case .empty:
                WelcomeView(isDropTargeted: isDropTargeted, onOpen: { open([$0]) })
            case .loading(let url):
                ProgressView {
                    Text("Opening “\(url.lastPathComponent)”…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                FailureView(message: message) {
                    model.close()
                }
            case .loaded:
                BrowserView(model: model)
            }
        }
        .navigationTitle(model.displayName)
        .focusedSceneValue(\.archiveModel, model)
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter(ArchiveTypes.isSupported)
            guard !supported.isEmpty else {
                model.errorMessage = String(localized: "Only RAR archives can be opened.")
                return false
            }
            open(supported)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted && model.state == .loaded {
                DropHighlight()
            }
        }
        .sheet(isPresented: $model.isPasswordPromptPresented) {
            PasswordPrompt(model: model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .onAppear {
            if let initialURL, model.state == .empty {
                model.open(initialURL)
            }
            consumePendingOpens()
        }
        .onChange(of: OpenRouter.shared.pending) {
            consumePendingOpens()
        }
    }

    private func consumePendingOpens() {
        guard !OpenRouter.shared.pending.isEmpty else { return }
        let urls = OpenRouter.shared.takeAll()
        open(urls)
    }

    /// Opens the first archive in this window when it is empty, the others in new windows.
    private func open(_ urls: [URL]) {
        var remaining = urls[...]
        if model.state == .empty || isFailed, let first = remaining.popFirst() {
            model.open(first)
        }
        for url in remaining {
            openWindow(id: "archive", value: url)
        }
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(6)
            .allowsHitTesting(false)
    }
}

private struct FailureView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not open the archive", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Open Another Archive…") {
                onDismiss()
                if let url = ArchivePanels.chooseArchive() {
                    OpenRouter.shared.enqueue([url])
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Close", action: onDismiss)
        }
    }
}
