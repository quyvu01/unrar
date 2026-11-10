import AppKit
import ArchiveKit
import SwiftUI
import UniformTypeIdentifiers

/// Main archive browser: folder sidebar, file table, inspector and status bar.
struct BrowserView: View {
    @Bindable var model: ArchiveViewModel
    @State private var showInspector = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 360)
        } detail: {
            FileTableView(model: model)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    BottomBar(model: model)
                }
                .navigationTitle(model.displayName)
                .navigationSubtitle(subtitle)
        }
        .inspector(isPresented: $showInspector) {
            ArchiveInfoView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search in archive"))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button {
                        model.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    .help("Back")

                    Button {
                        model.goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                }
                .controlGroupStyle(.navigation)

                Button {
                    model.goUp()
                } label: {
                    Label("Enclosing Folder", systemImage: "arrow.up")
                }
                .disabled(!model.canGoUp)
                .help("Enclosing Folder")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    ArchiveActions.extract(model: model, askDestination: false)
                } label: {
                    Label(model.selection.isEmpty ? LocalizedStringKey("Extract All") : LocalizedStringKey("Extract Selected"),
                          systemImage: "arrow.down.doc")
                }
                .disabled(model.isBusy)
                .help(model.selection.isEmpty ? Text("Extract every file") : Text("Extract the selected items"))

                Button {
                    ArchiveActions.extract(model: model, askDestination: true)
                } label: {
                    Label("Extract To…", systemImage: "folder.badge.plus")
                }
                .disabled(model.isBusy)
                .help("Choose where to extract")

                Button {
                    model.test()
                } label: {
                    Label("Test", systemImage: "checkmark.seal")
                }
                .disabled(model.isBusy)
                .help("Verify the integrity of the archive")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .help("Show archive information")
            }
        }
    }

    private var subtitle: String {
        guard let info = model.info else { return "" }
        let files = info.fileCount
        let size = Format.bytes(info.totalUncompressedSize)
        return String(localized: "\(files) files · \(size)")
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var model: ArchiveViewModel

    var body: some View {
        List(selection: folderSelection) {
            Section("Archive") {
                Label {
                    Text(model.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .tag("")
            }

            if let folders = model.root?.folderChildren {
                Section("Folders") {
                    OutlineGroup(folders, children: \.folderChildren) { node in
                        Label(node.name, systemImage: "folder")
                            .lineLimit(1)
                            .tag(node.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var folderSelection: Binding<String?> {
        Binding(
            get: { model.searchText.isEmpty ? model.currentFolderPath : nil },
            set: { path in
                if let path { model.navigate(to: path) }
            }
        )
    }
}

// MARK: - File table

struct FileTableView: View {
    @Bindable var model: ArchiveViewModel

    var body: some View {
        let nodes = model.visibleNodes
        let isSearching = !model.searchText.isEmpty
        // ZIP, 7z, TAR … do not expose per-file compressed sizes.
        let hasPackedSizes = model.info?.hasPackedSizes ?? true

        Table(of: ArchiveNode.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { node in
                NodeNameCell(node: node, showsLocation: isSearching)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Size", value: \.uncompressedSize) { node in
                Text(Format.bytes(node.uncompressedSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 86)

            TableColumn("Packed", value: \.compressedSize) { node in
                Text(hasPackedSizes ? Format.bytes(node.compressedSize) : "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 86)

            TableColumn("Ratio") { node in
                Text(hasPackedSizes ? Format.ratio(node) : "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 54)

            TableColumn("Modified", value: \.sortDate) { node in
                Text(Format.date(node.modificationDate))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
        } rows: {
            ForEach(nodes) { node in
                TableRow(node)
                    .itemProvider { model.itemProvider(for: node) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let node = model.root?.node(at: id) else { return }
            if node.isDirectory {
                model.enter(node)
            } else {
                model.openFile(node)
            }
        }
        .onKeyPress(.return) {
            guard model.selection.count == 1, let node = model.selectedNodes.first else { return .ignored }
            if node.isDirectory { model.enter(node) } else { model.openFile(node) }
            return .handled
        }
        .overlay {
            if nodes.isEmpty {
                if isSearching {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if !ids.isEmpty {
            let nodes = ids.compactMap { model.root?.node(at: $0) }
            if nodes.count == 1, let node = nodes.first {
                Button(node.isDirectory ? LocalizedStringKey("Open Folder") : LocalizedStringKey("Open")) {
                    model.openFile(node)
                }
                Divider()
            }
            Button("Extract") {
                model.selection = ids
                ArchiveActions.extract(model: model, askDestination: false)
            }
            .disabled(model.isBusy)
            Button("Extract To…") {
                model.selection = ids
                ArchiveActions.extract(model: model, askDestination: true)
            }
            .disabled(model.isBusy)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(nodes.map(\.path).sorted().joined(separator: "\n"), forType: .string)
            }
        }
    }
}

struct NodeNameCell: View {
    let node: ArchiveNode
    let showsLocation: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: node))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.entry?.isEncrypted == true {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Encrypted")
            }
            if node.entry?.isLink == true {
                Image(systemName: "arrow.turn.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Link")
            }
            if showsLocation, let parent = node.parent, !parent.path.isEmpty {
                Text(parent.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

/// Finder icons per file extension, cached.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: ArchiveNode) -> NSImage {
        let key = node.isDirectory ? "/folder" : (node.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
