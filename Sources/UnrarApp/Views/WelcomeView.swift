import AppKit
import SwiftUI

/// Empty window: a large drop zone plus recently opened archives.
struct WelcomeView: View {
    let isDropTargeted: Bool
    let onOpen: (URL) -> Void

    @State private var recents: [URL] = RecentArchives.urls

    var body: some View {
        HStack(spacing: 0) {
            dropZone
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)

            if !recents.isEmpty {
                Divider()
                recentList
                    .frame(width: 280)
            }
        }
        .background(.background)
        .onAppear { recents = RecentArchives.urls }
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 116, height: 116)
                Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "archivebox.fill")
                    .font(.system(size: 50, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .scaleEffect(isDropTargeted ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDropTargeted)

            VStack(spacing: 6) {
                Text("Drop a RAR archive here")
                    .font(.title2.weight(.semibold))
                Text("Browse its contents, extract everything or just the files you need.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                if let url = ArchivePanels.chooseArchive() { onOpen(url) }
            } label: {
                Label("Open Archive…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("Supports RAR 1.5 – RAR 7, encrypted and multi-part archives")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                )
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    RecentArchives.clear()
                    recents = []
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(recents, id: \.self) { url in
                        RecentRow(url: url) { onOpen(url) }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(.regularMaterial)
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(url.path)
    }
}
