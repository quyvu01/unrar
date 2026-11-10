import AppKit
import ArchiveKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// State of one archive window.
@MainActor
@Observable
final class ArchiveViewModel {
    enum LoadState: Equatable {
        case empty
        case loading(URL)
        case loaded
        case failed(String)
    }

    /// An operation that may need to be retried once the user typed a password.
    enum PendingAction {
        case open(URL)
        case extract(paths: Set<String>?, destination: URL, stripPrefix: String?)
        case test
        case openFile(path: String)
    }

    struct Operation: Identifiable {
        enum Kind { case extracting, testing }
        let id = UUID()
        let kind: Kind
        var progress = ExtractionProgress(bytesProcessed: 0, totalBytes: 0, filesProcessed: 0, totalFiles: 0)
        let startedAt = Date()
        var destination: URL?
    }

    struct Completion: Identifiable, Equatable {
        enum Kind: Equatable { case extracted(URL, count: Int, skipped: Int), tested(count: Int) }
        let id = UUID()
        let kind: Kind
    }

    // MARK: Archive

    private(set) var state: LoadState = .empty
    private(set) var archive: RARArchive?
    private(set) var info: ArchiveInfo?
    private(set) var root: ArchiveNode?
    private(set) var password: String?

    // MARK: Browsing

    private(set) var currentFolderPath: String = "" {
        didSet {
            if oldValue != currentFolderPath { selection = [] }
        }
    }
    var selection: Set<String> = []
    var searchText = ""
    var sortOrder: [KeyPathComparator<ArchiveNode>] = [KeyPathComparator(\.name)]
    private var history: [String] = []
    private var future: [String] = []

    // MARK: Operations and sheets

    private(set) var operation: Operation?
    var completion: Completion?
    var errorMessage: String?
    var isPasswordPromptPresented = false
    private(set) var passwordPromptIsRetry = false
    private var pendingAction: PendingAction?
    private var cancelFlag = CancelFlag()
    private var task: Task<Void, Never>?

    var displayName: String {
        if let archive { return archive.url.lastPathComponent }
        if case .loading(let url) = state { return url.lastPathComponent }
        return String(localized: "Unrar")
    }

    var currentFolder: ArchiveNode? {
        guard let root else { return nil }
        return root.node(at: currentFolderPath) ?? root
    }

    /// Rows for the table: the current folder, or search results across the whole archive.
    var visibleNodes: [ArchiveNode] {
        guard let folder = currentFolder, let root else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var nodes: [ArchiveNode]
        if query.isEmpty {
            nodes = folder.children
        } else {
            nodes = []
            Self.collect(root, where: { $0.name.localizedCaseInsensitiveContains(query) }, into: &nodes)
        }
        nodes.sort(using: sortOrder)
        // Folders always first, like Finder.
        return nodes.filter(\.isDirectory) + nodes.filter { !$0.isDirectory }
    }

    var selectedNodes: [ArchiveNode] {
        guard let root else { return [] }
        return selection.compactMap { root.node(at: $0) }
    }

    var isBusy: Bool { operation != nil }
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }
    var canGoUp: Bool { !currentFolderPath.isEmpty }

    private static func collect(_ node: ArchiveNode, where predicate: (ArchiveNode) -> Bool, into result: inout [ArchiveNode]) {
        for child in node.children {
            if predicate(child) { result.append(child) }
            if child.isDirectory { collect(child, where: predicate, into: &result) }
        }
    }

    // MARK: Opening

    func open(_ url: URL, password: String? = nil) {
        task?.cancel()
        state = .loading(url)
        errorMessage = nil
        completion = nil
        let archive = RARArchive(url: url)
        task = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ArchiveInfo, Error> in
                Result { try archive.readInfo(password: password) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let info):
                self.archive = archive
                self.info = info
                self.root = ArchiveNode.build(from: info.entries)
                self.password = password
                self.history = []
                self.future = []
                self.searchText = ""
                self.currentFolderPath = ""
                self.selection = []
                self.state = .loaded
                RecentArchives.add(archive.url)
                NSDocumentController.shared.noteNewRecentDocumentURL(archive.url)
            case .failure(let error):
                if let error = error as? ArchiveError, error == .passwordRequired || error == .wrongPassword {
                    self.state = self.archive == nil ? .empty : .loaded
                    self.askForPassword(retrying: .open(url), isRetry: error == .wrongPassword)
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func close() {
        task?.cancel()
        archive = nil
        info = nil
        root = nil
        password = nil
        state = .empty
        selection = []
        currentFolderPath = ""
    }

    // MARK: Navigation

    func enter(_ node: ArchiveNode) {
        guard node.isDirectory else { return }
        navigate(to: node.path)
    }

    func navigate(to path: String) {
        let current = currentFolderPath
        guard path != current else { return }
        history.append(current)
        future.removeAll()
        searchText = ""
        currentFolderPath = path
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        future.append(currentFolderPath)
        currentFolderPath = previous
    }

    func goForward() {
        guard let next = future.popLast() else { return }
        history.append(currentFolderPath)
        currentFolderPath = next
    }

    func goUp() {
        guard let folder = currentFolder, let parent = folder.parent else { return }
        navigate(to: parent.path)
    }

    // MARK: Extraction

    /// Paths and prefix to extract: the selection if any, otherwise everything.
    func extractionScope(selectionOnly: Bool) -> (paths: Set<String>?, stripPrefix: String?) {
        let selected = selectionOnly ? selection : []
        if selected.isEmpty { return (nil, nil) }
        // Selected items keep their structure relative to the folder they are shown in.
        let prefix = searchText.isEmpty ? currentFolderPath : ""
        return (selected, prefix.isEmpty ? nil : prefix)
    }

    /// Default destination according to the user's settings.
    func defaultDestination(settings: ExtractionSettings) -> URL? {
        guard let archive else { return nil }
        let base: URL
        switch settings.destinationMode {
        case .nextToArchive:
            base = archive.url.deletingLastPathComponent()
        case .customFolder:
            guard let folder = settings.customFolder else { return nil }
            base = folder
        case .ask:
            return nil
        }
        guard settings.createSubfolder else { return base }
        if settings.avoidDoubleFolder, let root, Self.hasSingleTopLevelFolder(root) {
            return base
        }
        return base.appendingPathComponent(Self.archiveStem(archive.url), isDirectory: true)
    }

    static func hasSingleTopLevelFolder(_ root: ArchiveNode) -> Bool {
        root.children.count == 1 && root.children[0].isDirectory
    }

    /// "Movie.part1.rar" -> "Movie", "Photos.rar" -> "Photos".
    static func archiveStem(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.isEmpty ? "Archive" : name
    }

    func extract(paths: Set<String>?, to destination: URL, stripPrefix: String?, settings: ExtractionSettings) {
        guard let archive, !isBusy else { return }
        let password = self.password
        let options = ExtractionOptions(overwrite: settings.overwritePolicy, stripPrefix: stripPrefix)
        let reveal = settings.revealInFinder
        start(.extracting, destination: destination) { flag, report in
            try archive.extract(paths: paths, to: destination, password: password, options: options) { progress in
                report(progress)
                return !flag.isCancelled
            }
        } onSuccess: { result in
            let count = result.extracted.count
            self.completion = Completion(kind: .extracted(destination, count: count, skipped: result.skipped.count))
            if reveal {
                let firstItems = result.extracted.filter { $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL }
                if firstItems.isEmpty || firstItems.count > 20 {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(firstItems)
                }
            }
        } retry: {
            .extract(paths: paths, destination: destination, stripPrefix: stripPrefix)
        }
    }

    func test() {
        guard let archive, !isBusy else { return }
        let password = self.password
        let count = info?.fileCount ?? 0
        start(.testing, destination: nil) { flag, report in
            try archive.test(password: password) { progress in
                report(progress)
                return !flag.isCancelled
            }
            return ExtractionResult()
        } onSuccess: { _ in
            self.completion = Completion(kind: .tested(count: count))
        } retry: {
            .test
        }
    }

    func cancelOperation() {
        cancelFlag.cancel()
    }

    private func start(_ kind: Operation.Kind,
                       destination: URL?,
                       work: @escaping @Sendable (CancelFlag, @escaping @Sendable (ExtractionProgress) -> Void) throws -> ExtractionResult,
                       onSuccess: @escaping (ExtractionResult) -> Void,
                       retry: @escaping () -> PendingAction) {
        let flag = CancelFlag()
        cancelFlag = flag
        completion = nil
        operation = Operation(kind: kind, destination: destination)

        let id = operation?.id
        let report: @Sendable (ExtractionProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.operation?.id == id else { return }
                self.operation?.progress = progress
            }
        }

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ExtractionResult, Error> in
                Result { try work(flag, report) }
            }.value
            self.operation = nil
            switch result {
            case .success(let value):
                onSuccess(value)
            case .failure(let error as ArchiveError) where error == .cancelled:
                break
            case .failure(let error as ArchiveError) where error == .passwordRequired || error == .wrongPassword:
                self.askForPassword(retrying: retry(), isRetry: error == .wrongPassword || self.password != nil)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Password

    private func askForPassword(retrying action: PendingAction, isRetry: Bool) {
        pendingAction = action
        passwordPromptIsRetry = isRetry
        isPasswordPromptPresented = true
    }

    func submitPassword(_ value: String, settings: ExtractionSettings) {
        isPasswordPromptPresented = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .open(let url):
            open(url, password: value)
        case .extract(let paths, let destination, let stripPrefix):
            password = value
            extract(paths: paths, to: destination, stripPrefix: stripPrefix, settings: settings)
        case .test:
            password = value
            test()
        case .openFile(let path):
            password = value
            if let node = root?.node(at: path) { openFile(node) }
        }
    }

    func cancelPasswordPrompt() {
        isPasswordPromptPresented = false
        if case .open = pendingAction, archive == nil { state = .empty }
        pendingAction = nil
    }

    var pendingArchiveName: String {
        if case .open(let url) = pendingAction { return url.lastPathComponent }
        return archive?.url.lastPathComponent ?? ""
    }

    // MARK: Quick open

    /// Extracts a single file to a temporary folder and opens it with its default app.
    func openFile(_ node: ArchiveNode) {
        if node.isDirectory {
            enter(node)
            return
        }
        guard let archive else { return }
        let password = self.password
        let path = node.path
        let parentPath = node.parent?.path ?? ""
        let name = node.name
        Task {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Unrar-Open", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    try archive.extract(paths: [path], to: folder, password: password,
                                        options: ExtractionOptions(overwrite: .overwrite,
                                                                   stripPrefix: parentPath.isEmpty ? nil : parentPath))
                    return folder.appendingPathComponent(name)
                }
            }.value
            switch result {
            case .success(let url):
                NSWorkspace.shared.open(url)
            case .failure(let error as ArchiveError) where error == .passwordRequired || error == .wrongPassword:
                self.askForPassword(retrying: .openFile(path: path), isRetry: error == .wrongPassword || self.password != nil)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Drag out

    /// Item provider that extracts `node` to a temporary folder when it is dropped
    /// (for example into Finder).
    func itemProvider(for node: ArchiveNode) -> NSItemProvider? {
        guard let archive else { return nil }
        let password = self.password
        let path = node.path
        let parentPath = node.parent?.path ?? ""
        let name = node.name
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)

        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Unrar-Drag", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try archive.extract(paths: [path], to: folder, password: password,
                                    options: ExtractionOptions(overwrite: .overwrite,
                                                               stripPrefix: parentPath.isEmpty ? nil : parentPath))
                completion(folder.appendingPathComponent(name), false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }
}

/// Thread-safe cancellation flag shared with the extraction thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
