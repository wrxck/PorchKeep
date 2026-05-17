import Foundation
import Combine

// ICloudCoordinator wraps NSMetadataQuery + startDownloadingUbiquitousItem so
// the UI can wait for an offloaded clip to be re-downloaded before AVPlayer
// tries to read it. Without this, dataless placeholders just produce a
// "couldn't open" error in the player.

@MainActor
final class ICloudCoordinator: ObservableObject {

    private let logger: AppLogger
    private var queries: [String: NSMetadataQuery] = [:]
    private var continuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var observers: [String: NSObjectProtocol] = [:]

    init(logger: AppLogger) {
        self.logger = logger
    }

    func downloadStatus(for url: URL) -> URLUbiquitousItemDownloadingStatus? {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return values?.ubiquitousItemDownloadingStatus
    }

    /// Ensure the file at `url` is fully present locally; if not, request it
    /// and await completion. Returns immediately when already current.
    func ensureLocal(_ url: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw NSError(domain: "PorchKeep", code: 404, userInfo: [NSLocalizedDescriptionKey: "File missing: \(url.lastPathComponent)"])
        }
        // A nil status means the file is not an iCloud item at all (local
        // storage mode) — it exists on disk, so there is nothing to download.
        let status = downloadStatus(for: url)
        if status == nil || status == .current {
            return
        }
        do { try fm.startDownloadingUbiquitousItem(at: url) }
        catch { logger.warn("startDownloadingUbiquitousItem failed: \(error)") }

        let key = url.path
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // A prior in-flight wait for the same file would otherwise be
            // orphaned (its awaiter hangs forever); resolve it first.
            if continuations[key] != nil {
                finish(key: key, error: CancellationError())
            }
            self.continuations[key] = cont
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, url.path)
            self.queries[key] = query
            let center = NotificationCenter.default
            let token = center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if let q = self.queries[key] { self.checkProgress(key: key, query: q) }
                }
            }
            self.observers[key] = token
            query.start()
            // Sanity timeout: 60s.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                self?.timeout(key: key)
            }
        }
    }

    private func checkProgress(key: String, query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        for item in query.results {
            guard let mdItem = item as? NSMetadataItem else { continue }
            let status = mdItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                finish(key: key, error: nil)
                return
            }
        }
    }

    private func timeout(key: String) {
        guard continuations[key] != nil else { return }
        finish(key: key, error: NSError(domain: "PorchKeep", code: 408, userInfo: [NSLocalizedDescriptionKey: "iCloud download timed out"]))
    }

    private func finish(key: String, error: Error?) {
        if let q = queries.removeValue(forKey: key) { q.stop() }
        if let obs = observers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(obs)
        }
        if let cont = continuations.removeValue(forKey: key) {
            if let error = error { cont.resume(throwing: error) }
            else { cont.resume() }
        }
    }
}
