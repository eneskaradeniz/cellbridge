import Foundation

/// A rolling text log on disk. The on-screen list dies with the app; this one survives restarts, so a connection that
/// dropped overnight can be examined afterwards. Lines never contain numbers or message text.
final class EventLog: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "cellbridge.eventlog")

    init(url: URL, maxBytes: Int = 200_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ line: String) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data((line + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    // Readable after the first unlock so events from a locked phone can still be written.
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                try rotateIfNeeded()
            } catch {
                // Logging must never take the app down.
            }
        }
    }

    /// The newest `count` lines, oldest first.
    func recent(_ count: Int) -> [String] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
        }
    }

    /// Over the limit, the older half of the lines goes.
    private func rotateIfNeeded() throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try Data(kept.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
