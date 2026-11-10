import ArchiveKit
import Foundation
import SwiftUI

enum DestinationMode: String, CaseIterable, Identifiable {
    case nextToArchive
    case customFolder
    case ask

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .nextToArchive: return "Next to the archive"
        case .customFolder: return "In a fixed folder"
        case .ask: return "Ask every time"
        }
    }
}

enum SettingsKey {
    static let destinationMode = "destinationMode"
    static let customFolder = "customFolderPath"
    static let createSubfolder = "createSubfolder"
    static let avoidDoubleFolder = "avoidDoubleFolder"
    static let overwritePolicy = "overwritePolicy"
    static let revealInFinder = "revealInFinder"
    static let showHiddenFiles = "showHiddenFiles"
}

/// Snapshot of the extraction preferences (stored in UserDefaults via @AppStorage).
struct ExtractionSettings {
    var destinationMode: DestinationMode
    var customFolder: URL?
    var createSubfolder: Bool
    var avoidDoubleFolder: Bool
    var overwritePolicy: OverwritePolicy
    var revealInFinder: Bool

    static var current: ExtractionSettings {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            SettingsKey.destinationMode: DestinationMode.nextToArchive.rawValue,
            SettingsKey.createSubfolder: true,
            SettingsKey.avoidDoubleFolder: true,
            SettingsKey.overwritePolicy: OverwritePolicy.rename.rawValue,
            SettingsKey.revealInFinder: true,
        ])
        let folder = defaults.string(forKey: SettingsKey.customFolder).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return ExtractionSettings(
            destinationMode: DestinationMode(rawValue: defaults.string(forKey: SettingsKey.destinationMode) ?? "") ?? .nextToArchive,
            customFolder: folder,
            createSubfolder: defaults.bool(forKey: SettingsKey.createSubfolder),
            avoidDoubleFolder: defaults.bool(forKey: SettingsKey.avoidDoubleFolder),
            overwritePolicy: OverwritePolicy(rawValue: defaults.string(forKey: SettingsKey.overwritePolicy) ?? "") ?? .rename,
            revealInFinder: defaults.bool(forKey: SettingsKey.revealInFinder)
        )
    }
}

extension OverwritePolicy {
    var title: LocalizedStringKey {
        switch self {
        case .rename: return "Keep both (rename new file)"
        case .overwrite: return "Replace existing files"
        case .skip: return "Skip existing files"
        }
    }
}

/// Recently opened archives, most recent first.
enum RecentArchives {
    private static let key = "recentArchives"
    private static let limit = 8

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func ratio(_ node: ArchiveNode) -> String {
        guard node.uncompressedSize > 0 else { return "–" }
        let ratio = Double(node.compressedSize) / Double(node.uncompressedSize)
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, seconds)) ?? ""
    }
}

extension ArchiveNode {
    /// Non-optional date for table sorting.
    var sortDate: Date { modificationDate ?? .distantPast }
}
