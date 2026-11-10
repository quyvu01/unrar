import Foundation

// MARK: - Progress

final class ProgressBox {
    private(set) var state: ExtractionProgress
    private let callback: ((ExtractionProgress) -> Bool)?
    private(set) var shouldContinue = true
    private var lastReport = Date.distantPast

    init(state: ExtractionProgress, callback: ((ExtractionProgress) -> Bool)?) {
        self.state = state
        self.callback = callback
    }

    @discardableResult
    func add(bytes: Int64, report: Bool = true) -> Bool {
        if bytes > 0 { state.bytesProcessed += UInt64(bytes) }
        if report { reportIfNeeded(force: false) }
        return shouldContinue
    }

    /// Sets the processed byte count directly (used when progress is measured
    /// on the compressed input rather than on the extracted data).
    @discardableResult
    func set(bytes: UInt64) -> Bool {
        state.bytesProcessed = state.totalBytes > 0 ? min(bytes, state.totalBytes) : bytes
        reportIfNeeded(force: false)
        return shouldContinue
    }

    func begin(path: String) {
        state.currentPath = path
        reportIfNeeded(force: state.filesProcessed == 0)
    }

    func finishFile() {
        state.filesProcessed += 1
        reportIfNeeded(force: state.filesProcessed == state.totalFiles)
    }

    private func reportIfNeeded(force: Bool) {
        guard let callback, shouldContinue else { return }
        let now = Date()
        // Throttle to ~30 updates per second.
        guard force || now.timeIntervalSince(lastReport) > 0.033 else { return }
        lastReport = now
        if !callback(state) { shouldContinue = false }
    }
}
