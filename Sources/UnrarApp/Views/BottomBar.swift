import AppKit
import ArchiveKit
import SwiftUI

/// Status line under the file table. Shows progress while extracting/testing and
/// a result banner afterwards.
struct BottomBar: View {
    @Bindable var model: ArchiveViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if let operation = model.operation {
                    OperationProgressView(operation: operation) {
                        model.cancelOperation()
                    }
                } else if let completion = model.completion {
                    CompletionBanner(completion: completion) {
                        withAnimation { model.completion = nil }
                    }
                } else {
                    statusLine
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: model.operation?.id)
        .animation(.easeInOut(duration: 0.2), value: model.completion)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if model.selection.isEmpty {
                let nodes = model.visibleNodes
                Text("\(nodes.count) items")
                Text("·").foregroundStyle(.tertiary)
                Text(Format.bytes(nodes.reduce(0) { $0 + $1.uncompressedSize }))
            } else {
                let nodes = model.selectedNodes
                Text("\(nodes.count) of \(model.visibleNodes.count) selected")
                Text("·").foregroundStyle(.tertiary)
                Text(Format.bytes(nodes.reduce(0) { $0 + $1.uncompressedSize }))
            }
            Spacer()
            if model.info?.hasEncryptedEntries == true {
                Label(model.password == nil ? LocalizedStringKey("Encrypted") : LocalizedStringKey("Unlocked"),
                      systemImage: model.password == nil ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(model.password == nil ? Color.orange : Color.green)
            }
            if model.info?.isSolid == true {
                Label("Solid", systemImage: "square.stack.3d.up.fill")
            }
            if model.info?.isMultiVolume == true {
                Label("Multi-part", systemImage: "square.split.2x1")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}

private struct OperationProgressView: View {
    let operation: ArchiveViewModel.Operation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: operation.kind == .extracting ? "arrow.down.doc.fill" : "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(operation.kind == .extracting ? LocalizedStringKey("Extracting…") : LocalizedStringKey("Testing…"))
                        .fontWeight(.semibold)
                    Text(operation.progress.currentPath ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(operation.progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: operation.progress.fractionCompleted)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Format.bytes(operation.progress.bytesProcessed)) of \(Format.bytes(operation.progress.totalBytes))")
                    Spacer()
                    if let detail = speedAndRemaining {
                        Text(detail)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            Button(role: .cancel, action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .keyboardShortcut(.cancelAction)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var speedAndRemaining: String? {
        let elapsed = Date().timeIntervalSince(operation.startedAt)
        let done = Double(operation.progress.bytesProcessed)
        guard elapsed > 0.5, done > 0 else { return nil }
        let speed = done / elapsed
        let remaining = max(0, Double(operation.progress.totalBytes) - done) / speed
        let speedText = Format.bytes(UInt64(speed))
        return String(localized: "\(speedText)/s · \(Format.duration(remaining)) left")
    }
}

private struct CompletionBanner: View {
    let completion: ArchiveViewModel.Completion
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            switch completion.kind {
            case .extracted(let url, let count, let skipped):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extracted \(count) items")
                        .fontWeight(.semibold)
                    Group {
                        if skipped > 0 {
                            Text("To “\(url.lastPathComponent)” · \(skipped) existing files skipped")
                        } else {
                            Text("To “\(url.lastPathComponent)”")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .tested(let count):
                VStack(alignment: .leading, spacing: 2) {
                    Text("No errors found")
                        .fontWeight(.semibold)
                    Text("\(count) files tested successfully")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
