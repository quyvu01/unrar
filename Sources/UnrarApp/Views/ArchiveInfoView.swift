import AppKit
import ArchiveKit
import SwiftUI

/// Inspector with archive properties and the archive comment.
struct ArchiveInfoView: View {
    let model: ArchiveViewModel

    var body: some View {
        if let info = model.info, let archive = model.archive {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: archive.url.path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(archive.url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(2)
                            Text(formatName(info))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Contents") {
                    LabeledContent("Files", value: "\(info.fileCount)")
                    LabeledContent("Folders", value: "\(info.entries.count - info.fileCount)")
                    LabeledContent("Original size", value: Format.bytes(info.totalUncompressedSize))
                    LabeledContent("Packed size", value: Format.bytes(info.totalCompressedSize))
                    LabeledContent("Ratio", value: ratio(info))
                }

                Section("Properties") {
                    if info.isRAR { flag("Solid archive", info.isSolid) }
                    flag("Encrypted files", info.entries.contains { $0.isEncrypted })
                    flag("Encrypted file names", info.hasEncryptedHeaders)
                    flag("Multi-part archive", info.isMultiVolume)
                    if info.isRAR {
                        flag("Recovery record", info.hasRecoveryRecord)
                        flag("Locked", info.isLocked)
                    }
                }

                if let selected = selectedEntry {
                    Section("Selected item") {
                        LabeledContent("Name", value: selected.name)
                        LabeledContent("Size", value: Format.bytes(selected.uncompressedSize))
                        if info.hasPackedSizes {
                            LabeledContent("Packed", value: Format.bytes(selected.compressedSize))
                        }
                        LabeledContent("Modified", value: Format.date(selected.modificationDate))
                        if !selected.isDirectory, info.isRAR {
                            LabeledContent("CRC32", value: String(format: "%08X", selected.crc32))
                            LabeledContent("Method", value: selected.methodName)
                        }
                    }
                }

                if let comment = info.comment, !comment.isEmpty {
                    Section("Comment") {
                        Text(comment)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section("Location") {
                    Text(archive.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([archive.url])
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No archive", systemImage: "archivebox")
        }
    }

    private var selectedEntry: ArchiveEntry? {
        guard model.selection.count == 1 else { return nil }
        return model.selectedNodes.first?.entry
    }

    private func flag(_ title: LocalizedStringKey, _ value: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: value ? "checkmark.circle.fill" : "minus")
                .foregroundStyle(value ? Color.green : Color.secondary)
        }
    }

    private func ratio(_ info: ArchiveInfo) -> String {
        guard info.totalUncompressedSize > 0 else { return "–" }
        let value = Double(info.totalCompressedSize) / Double(info.totalUncompressedSize)
        return value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func formatName(_ info: ArchiveInfo) -> String {
        info.formatName
    }
}
