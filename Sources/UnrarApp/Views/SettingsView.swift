import AppKit
import ArchiveKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ExtractionSettingsView()
                .tabItem { Label("Extraction", systemImage: "arrow.down.doc") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExtractionSettingsView: View {
    @AppStorage(SettingsKey.destinationMode) private var destinationMode = DestinationMode.nextToArchive
    @AppStorage(SettingsKey.customFolder) private var customFolderPath = ""
    @AppStorage(SettingsKey.createSubfolder) private var createSubfolder = true
    @AppStorage(SettingsKey.avoidDoubleFolder) private var avoidDoubleFolder = true
    @AppStorage(SettingsKey.overwritePolicy) private var overwritePolicy = OverwritePolicy.rename
    @AppStorage(SettingsKey.revealInFinder) private var revealInFinder = true

    var body: some View {
        Form {
            Section("Destination") {
                Picker("Extract files", selection: $destinationMode) {
                    ForEach(DestinationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if destinationMode == .customFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(customFolderPath.isEmpty
                                 ? String(localized: "None")
                                 : (customFolderPath as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                if let url = ArchivePanels.chooseDestination(startingAt: nil) {
                                    customFolderPath = url.path
                                }
                            }
                        }
                    }
                }

                Toggle("Create a folder named after the archive", isOn: $createSubfolder)
                Toggle("Don’t create it when the archive has a single top-level folder", isOn: $avoidDoubleFolder)
                    .disabled(!createSubfolder)
            }

            Section("Existing files") {
                Picker("When a file already exists", selection: $overwritePolicy) {
                    ForEach(OverwritePolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
            }

            Section("After extraction") {
                Toggle("Show extracted files in Finder", isOn: $revealInFinder)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Unrar")
                        .font(.title2.weight(.semibold))
                    Text("A modern RAR extractor for macOS")
                        .foregroundStyle(.secondary)
                    Text("UnRAR library version \(RARArchive.libraryVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Divider()
            Text("RAR decompression is provided by the UnRAR source code by Alexander Roshal.")
                .font(.callout)
            ScrollView {
                Text(unrarLicenseNotice)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
    }
}

/// Required by the UnRAR license (paragraph 2).
let unrarLicenseNotice = """
UnRAR source code may be used in any software to handle RAR archives \
without limitations free of charge, but cannot be used to develop RAR \
(WinRAR) compatible archiver and to re-create RAR compression algorithm, \
which is proprietary. Distribution of modified UnRAR source code in \
separate form or as a part of other software is permitted, provided that \
full text of this paragraph, starting from "UnRAR source code" words, is \
included in license, or in documentation if license is not available, and \
in source code comments of resulting package.

THE RAR ARCHIVER AND THE UnRAR UTILITY ARE DISTRIBUTED "AS IS". NO WARRANTY \
OF ANY KIND IS EXPRESSED OR IMPLIED. YOU USE AT YOUR OWN RISK.
"""
