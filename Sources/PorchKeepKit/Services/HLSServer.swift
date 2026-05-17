import Foundation
import Network

// A minimal loopback-only HTTP server for the live HLS directory.
//
// AVPlayer does not reliably play HLS from file:// URLs — it expects the
// playlist and segments over HTTP. This serves exactly the work directory
// ffmpeg writes into, bound to 127.0.0.1 on a random port (loopback-only, so
// macOS raises no incoming-connection firewall prompt).

@MainActor
final class HLSServer {
    private var listener: NWListener?
    private var directory: URL = FileManager.default.temporaryDirectory
    private let logger: AppLogger

    init(logger: AppLogger) { self.logger = logger }

    /// Starts serving `directory`; returns the playlist URL, or nil on failure.
    func start(directory: URL, playlist: String = "live.m3u8") async -> URL? {
        self.directory = directory
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else {
            logger.error("HLSServer: could not create listener")
            return nil
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in self?.serve(conn) }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !resumed, let port = listener.port?.rawValue else { return }
                    resumed = true
                    let url = URL(string: "http://127.0.0.1:\(port)/\(playlist)")!
                    self.logger.writeRaw(.info, "HLS server ready at \(url)")
                    cont.resume(returning: url)
                case .failed(let err):
                    guard !resumed else { return }
                    resumed = true
                    self.logger.writeRaw(.error, "HLSServer failed: \(err)")
                    cont.resume(returning: nil)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            Task { @MainActor in self.respond(to: request, on: conn) }
        }
    }

    private func respond(to request: String, on conn: NWConnection) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if path.hasPrefix("/") { path.removeFirst() }
        // Refuse path traversal — only serve plain filenames in the work dir.
        guard !path.contains(".."), !path.contains("/"), !path.isEmpty else {
            send(conn, status: "403 Forbidden", contentType: "text/plain", body: Data("forbidden".utf8))
            return
        }
        let fileURL = directory.appendingPathComponent(path)
        guard let body = try? Data(contentsOf: fileURL) else {
            send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
            return
        }
        let ctype: String
        if path.hasSuffix(".m3u8") { ctype = "application/vnd.apple.mpegurl" }
        else if path.hasSuffix(".ts") { ctype = "video/mp2t" }
        else { ctype = "application/octet-stream" }
        send(conn, status: "200 OK", contentType: ctype, body: body)
    }

    private func send(_ conn: NWConnection, status: String, contentType: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
